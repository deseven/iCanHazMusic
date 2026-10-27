#include "All.h"
#include "WAVInputSource.h"
#include "IAPEIO.h"
#include "BufferIO.h"
#include "MACLib.h"
#include "GlobalFunctions.h"
#include "WholeFileIO.h"

namespace APE
{

/**************************************************************************************************
Input source creation
**************************************************************************************************/
CInputSource * CInputSource::CreateInputSource(const str_utfn * pSourceName, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int32 * pFlags, IID3v2Tag * pTag, bool bReadFullInputForUnknownLength, int * pErrorCode)
{
    // error check the parameters
    if ((pSourceName == APE_NULL) || (wcslen(pSourceName) == 0))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_BAD_PARAMETER;
        return APE_NULL;
    }

    // get the extension
    const str_utfn * pExtension = &pSourceName[wcslen(pSourceName)];
    while ((pExtension > pSourceName) && (*pExtension != '.'))
        pExtension--;

    // open the file
    CSmartPtr<IAPEIO> spIO(CreateIAPEIO());
    if (spIO->Open(pSourceName, true) != APE_ERROR_SUCCESS)
    {
        *pErrorCode = APE_ERROR_INVALID_INPUT_FILE;
        return APE_NULL;
    }

    // read header
    BYTE aryHeader[64];
    CSmartPtr<CHeaderIO> spHeaderIO(new CHeaderIO(spIO));
    if (spHeaderIO->ReadHeader(aryHeader) == false)
    {
        *pErrorCode = APE_ERROR_IO_READ;
        return APE_NULL;
    }

    // set as reader
    spHeaderIO.SetDelete(false);
    spIO.SetDelete(false);
    spIO.Assign(spHeaderIO);
    spIO.SetDelete(true); // this is redundant because Assign sets it, but it's here for clarity

    // read header
    if (CWAVInputSource::GetHeaderMatches(aryHeader))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_SUCCESS;
        CInputSource * pWAV = new CWAVInputSource(spIO, pwfeSource, pTotalBlocks, pHeaderBytes, pTerminatingBytes, pTag, bReadFullInputForUnknownLength, pErrorCode);
        spIO.SetDelete(false);
        if (pWAV->GetFloat())
            *pFlags |= APE_FORMAT_FLAG_FLOATING_POINT;
        return pWAV;
    }
    else if (CAIFFInputSource::GetHeaderMatches(aryHeader))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_SUCCESS;
        *pFlags |= APE_FORMAT_FLAG_AIFF;
        CAIFFInputSource * pAIFF = new CAIFFInputSource(spIO, pwfeSource, pTotalBlocks, pHeaderBytes, pTerminatingBytes, pTag, pErrorCode);
        spIO.SetDelete(false);
        if (pAIFF->GetIsBigEndian())
            *pFlags |= APE_FORMAT_FLAG_BIG_ENDIAN;
        if ((pwfeSource->wBitsPerSample == 8) && pAIFF->GetIsSigned8Bit())
            *pFlags |= APE_FORMAT_FLAG_SIGNED_8_BIT;
        if (pwfeSource->wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
            *pFlags |= APE_FORMAT_FLAG_FLOATING_POINT;
        return pAIFF;
    }
    else if (CW64InputSource::GetHeaderMatches(aryHeader))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_SUCCESS;
        *pFlags |= APE_FORMAT_FLAG_W64;
        CW64InputSource * pW64 = new CW64InputSource(spIO, pwfeSource, pTotalBlocks, pHeaderBytes, pTerminatingBytes, pErrorCode);
        spIO.SetDelete(false);
        if (pwfeSource->wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
            *pFlags |= APE_FORMAT_FLAG_FLOATING_POINT;
        return pW64;
    }
    else if (CSNDInputSource::GetHeaderMatches(aryHeader))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_SUCCESS;
        CSNDInputSource * pSND = new CSNDInputSource(spIO, pwfeSource, pTotalBlocks, pHeaderBytes, pTerminatingBytes, pErrorCode, pFlags);
        spIO.SetDelete(false);
        if (pwfeSource->wBitsPerSample == 8)
            *pFlags |= APE_FORMAT_FLAG_SIGNED_8_BIT;
        if (pwfeSource->wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
            *pFlags |= APE_FORMAT_FLAG_FLOATING_POINT;
        return pSND;
    }
    else if (CCAFInputSource::GetHeaderMatches(aryHeader))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_SUCCESS;
        CCAFInputSource * pCAF = new CCAFInputSource(spIO, pwfeSource, pTotalBlocks, pHeaderBytes, pTerminatingBytes, pErrorCode);
        spIO.SetDelete(false);
        *pFlags |= APE_FORMAT_FLAG_CAF;
        if (pCAF->GetIsBigEndian())
            *pFlags |= APE_FORMAT_FLAG_BIG_ENDIAN;
        if (pwfeSource->wBitsPerSample == 8)
            *pFlags |= APE_FORMAT_FLAG_SIGNED_8_BIT;
        if (pwfeSource->wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
            *pFlags |= APE_FORMAT_FLAG_FLOATING_POINT;
        return pCAF;
    }
    else
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_INVALID_INPUT_FILE;
        return APE_NULL;
    }
}

struct CInputSource::RIFF_HEADER
{
    char cRIFF[4];                // the characters 'RIFF' indicating that it's a RIFF file
    uint32_t nBytes;              // the number of bytes following this header
};

/**************************************************************************************************
CInputSource - base input format class (allows multiple format support)
**************************************************************************************************/
int CInputSource::GetHeaderDataHelper(bool bIsValid, unsigned char * pBuffer, uint32_t nHeaderBytes, IAPEIO * pIO)
{
    if (!bIsValid) return APE_ERROR_UNDEFINED;

    int nResult = APE_ERROR_SUCCESS;

    if (nHeaderBytes > 0)
    {
        const int64 nOriginalFileLocation = pIO->GetPosition();

        if (nOriginalFileLocation != 0)
        {
            pIO->Seek(0, SeekFileBegin);
        }

        int64 nBytesRead = 0;
        const int nReadRetVal = pIO->Read(pBuffer, nHeaderBytes, &nBytesRead);

        if ((nReadRetVal != APE_ERROR_SUCCESS) || (nHeaderBytes != nBytesRead))
        {
            nResult = APE_ERROR_UNDEFINED;
        }

        pIO->Seek(nOriginalFileLocation, SeekFileBegin);
    }

    return nResult;
}

int CInputSource::GetTerminatingDataHelper(bool bIsValid, unsigned char * pBuffer, uint32_t nTerminatingBytes, IAPEIO * pIO)
{
    if (!bIsValid) return APE_ERROR_UNDEFINED;

    int nResult = APE_ERROR_SUCCESS;

    if (nTerminatingBytes > 0)
    {
        const int64 nOriginalFileLocation = pIO->GetPosition();

        pIO->Seek(-static_cast<int64>(nTerminatingBytes), SeekFileEnd);

        int64 nBytesRead = 0;
        const int nReadRetVal = pIO->Read(pBuffer, nTerminatingBytes, &nBytesRead);

        if ((nReadRetVal != APE_ERROR_SUCCESS) || (nTerminatingBytes != nBytesRead))
        {
            nResult = APE_ERROR_UNDEFINED;
        }

        pIO->Seek(nOriginalFileLocation, SeekFileBegin);
    }

    return nResult;
}

void CInputSource::Convert8BitSignedToUnsigned(unsigned char * pBuffer, int nChannels, int nBlocks)
{
    for (int nSample = 0; nSample < nBlocks * nChannels; nSample++)
    {
        const char cTemp = static_cast<char>(pBuffer[nSample]);
        const unsigned char cConvert = static_cast<unsigned char>(static_cast<int>(cTemp) + 128);
        pBuffer[nSample] = cConvert;
    }
}

/**************************************************************************************************
CWAVInputSource - wraps working with WAV files
**************************************************************************************************/
struct CWAVInputSource::DATA_TYPE_ID_HEADER
{
    char cDataTypeID[4];          // should equal 'WAVE' for a WAV file
};

struct CWAVInputSource::RIFF_CHUNK_HEADER
{
    char cChunkLabel[4];          // should equal "data" indicating the data chunk
    uint32_t nChunkBytes;         // the bytes of the chunk
};

struct CWAVInputSource::WAV_FORMAT_HEADER
{
    uint16 nFormatTag;            // the format of the WAV...should equal 1 for a PCM file
    uint16 nChannels;             // the number of channels
    uint32_t nSamplesPerSecond;   // the number of samples per second
    uint32_t nBytesPerSecond;     // the bytes per second
    uint16 nBlockAlign;           // block alignment
    uint16 nBitsPerSample;        // the number of bits per sample
};

/*static*/ bool CWAVInputSource::GetHeaderMatches(BYTE aryHeader[64])
{
    if ((aryHeader[0] == 'R' && aryHeader[1] == 'I' && aryHeader[2] == 'F' && aryHeader[3] == 'F') ||
        (aryHeader[0] == 'R' && aryHeader[1] == 'F' && aryHeader[2] == '6' && aryHeader[3] == '4') ||
        (aryHeader[0] == 'B' && aryHeader[1] == 'W' && aryHeader[2] == '6' && aryHeader[3] == '4'))
    {
        return true;
    }

    return false;
}

CWAVInputSource::CWAVInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, IID3v2Tag * pTag, bool bReadFullInputForUnknownLength, int * pErrorCode)
{
    m_bIsValid = false;
    m_nDataBytes = 0;
    m_nTerminatingBytes = 0;
    m_nFileBytes = 0;
    m_nHeaderBytes = 0;
    m_bFloat = false; // we need a boolean instead of just checking WAVE_FORMAT_IEEE_FLOAT since it can be extensible with the format float
    m_bUnknownLengthFile = false;
    m_pTag = pTag;

    if (pIO == APE_NULL || pwfeSource == APE_NULL)
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_BAD_PARAMETER;
        return;
    }

    // store the reader
    m_spIO.Assign(pIO);

    // if we're an undefined size, try reading the whole file
    if (bReadFullInputForUnknownLength && (pIO->GetSize() == APE_FILE_SIZE_UNDEFINED))
    {
        CWholeFileIO * pWholeFile = CWholeFileIO::CreateWholeFileIO(m_spIO, APE_FILE_SIZE_UNDEFINED);
        if (pWholeFile != APE_NULL)
        {
            m_spIO.SetDelete(false);
            m_spIO.Assign(pWholeFile);
            m_spIO.SetDelete(true);
        }
    }

    // read to a buffer so pipes work (that way we don't have to seek back to get the header)
    m_spIO.SetDelete(false);
    m_spIO.Assign(new CBufferIO(m_spIO, APE_BYTES_IN_KILOBYTE * 256));
    m_spIO.SetDelete(true);

    // analyze source
    int nResult = AnalyzeSource();
    if ((nResult == APE_ERROR_SUCCESS) && (m_wfeSource.nBlockAlign > 0))
    {
        // fill in the parameters
        if (pwfeSource) memcpy(pwfeSource, &m_wfeSource, sizeof(WAVEFORMATEX));
        if (pTotalBlocks) *pTotalBlocks = m_nDataBytes / static_cast<int64>(m_wfeSource.nBlockAlign);
        if (pHeaderBytes) *pHeaderBytes = m_nHeaderBytes;
        if (pTerminatingBytes) *pTerminatingBytes = m_nTerminatingBytes;

        m_bIsValid = true;
    }

    if (pErrorCode) *pErrorCode = nResult;
}

CWAVInputSource::~CWAVInputSource()
{
}

int CWAVInputSource::AnalyzeSource()
{
    // get the file size
    m_nFileBytes = m_spIO->GetSize();

    // get the RIFF header
    CInputSource::RIFF_HEADER RIFFHeader;
    APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &RIFFHeader, sizeof(RIFFHeader)))

    // make sure the RIFF header is valid
    if (!(RIFFHeader.cRIFF[0] == 'R' && RIFFHeader.cRIFF[1] == 'I' && RIFFHeader.cRIFF[2] == 'F' && RIFFHeader.cRIFF[3] == 'F') &&
        !(RIFFHeader.cRIFF[0] == 'R' && RIFFHeader.cRIFF[1] == 'F' && RIFFHeader.cRIFF[2] == '6' && RIFFHeader.cRIFF[3] == '4') &&
        !(RIFFHeader.cRIFF[0] == 'B' && RIFFHeader.cRIFF[1] == 'W' && RIFFHeader.cRIFF[2] == '6' && RIFFHeader.cRIFF[3] == '4'))
    {
        return APE_ERROR_INVALID_INPUT_FILE;
    }

    // handle size in the RIFF header
    if (m_nFileBytes == APE_FILE_SIZE_UNDEFINED)
    {
        // if we're unknown size flag that file as such
        m_bUnknownLengthFile = true;
    }
    else
    {
        // we used to check the RIFFHeader.nBytes and switch the number to -1 (undefined) in several cases
        // but I don't think anything was actually using the size, so this was removed 6/12/2025

        // I thought about adding checks that the size of the RIFF header plus the header bytes matched the file size, but David Bryant told me not to because lots of
        // files have wonky values so just allowing anything is better (6/15/2025). I have checks like this in the AIFF, W64, etc. code.
    }

    // read the data type header
    CWAVInputSource::DATA_TYPE_ID_HEADER DataTypeIDHeader;
    APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &DataTypeIDHeader, sizeof(DataTypeIDHeader)))

    // make sure it's the right data type
    if (!(DataTypeIDHeader.cDataTypeID[0] == 'W' && DataTypeIDHeader.cDataTypeID[1] == 'A' && DataTypeIDHeader.cDataTypeID[2] == 'V' && DataTypeIDHeader.cDataTypeID[3] == 'E'))
        return APE_ERROR_INVALID_INPUT_FILE;

    // the chunk size specified in the DS64 block (if found)
    int64 nDS64DataBytes = -1;

    // find the 'fmt ' chunk
    CWAVInputSource::RIFF_CHUNK_HEADER RIFFChunkHeader;
    APE_RETURN_ON_ERROR(ReadRIFFHeader(RIFFChunkHeader))

    while (!(RIFFChunkHeader.cChunkLabel[0] == 'f' && RIFFChunkHeader.cChunkLabel[1] == 'm' && RIFFChunkHeader.cChunkLabel[2] == 't' && RIFFChunkHeader.cChunkLabel[3] == ' '))
    {
        // check if the header stretches past the end of the file (then we're not valid)
        if (m_nFileBytes != APE_FILE_SIZE_UNDEFINED)
        {
            if (RIFFChunkHeader.nChunkBytes > (m_nFileBytes - m_spIO->GetPosition()))
            {
                return APE_ERROR_INVALID_INPUT_FILE;
            }
        }

        // we need to read the chunk so CBufferIO objects keep working nicely (seeking is tricky for them)
        CSmartPtr<unsigned char> spExtraChunk(RIFFChunkHeader.nChunkBytes);
        APE_RETURN_ON_ERROR(ReadSafe(m_spIO, spExtraChunk, static_cast<int>(RIFFChunkHeader.nChunkBytes)))

        if (RIFFChunkHeader.cChunkLabel[0] == 'd' && RIFFChunkHeader.cChunkLabel[1] == 's' && RIFFChunkHeader.cChunkLabel[2] == '6' && RIFFChunkHeader.cChunkLabel[3] == '4')
        {
            // this is the size of the file
            #pragma pack(push, 1)
            struct DS64HeaderStart
            {
                uint64_t riffSize64;
                uint64_t dataSize64;
                uint64_t sampleCount64;
                uint32_t tableLength;
            };
            #pragma pack(pop)
            if (RIFFChunkHeader.nChunkBytes >= sizeof(DS64HeaderStart))
            {
                DS64HeaderStart Header;
                APE_CLEAR(Header);
                memcpy(&Header, spExtraChunk.GetPtr(), sizeof(DS64HeaderStart));
                nDS64DataBytes = static_cast<int64>(Header.dataSize64);
            }
        }

        // check again for the data chunk
        APE_RETURN_ON_ERROR(ReadRIFFHeader(RIFFChunkHeader))
    }

    // read the format info
    CWAVInputSource::WAV_FORMAT_HEADER WAVFormatHeader;
    APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &WAVFormatHeader, sizeof(WAVFormatHeader)))

    WAVFormatHeader.nFormatTag = ConvertU16LE(WAVFormatHeader.nFormatTag);
    WAVFormatHeader.nChannels = ConvertU16LE(WAVFormatHeader.nChannels);
    WAVFormatHeader.nSamplesPerSecond = ConvertU32LE(WAVFormatHeader.nSamplesPerSecond);
    WAVFormatHeader.nBytesPerSecond = ConvertU32LE(WAVFormatHeader.nBytesPerSecond);
    WAVFormatHeader.nBlockAlign = ConvertU16LE(WAVFormatHeader.nBlockAlign);
    WAVFormatHeader.nBitsPerSample = ConvertU16LE(WAVFormatHeader.nBitsPerSample);

    // error check the header to see if we support it
    if ((WAVFormatHeader.nFormatTag != WAVE_FORMAT_PCM) && (WAVFormatHeader.nFormatTag != WAVE_FORMAT_EXTENSIBLE) && (WAVFormatHeader.nFormatTag != WAVE_FORMAT_IEEE_FLOAT))
        return APE_ERROR_INVALID_INPUT_FILE;

    #ifndef APE_SUPPORT_FLOAT_COMPRESSION
        if (WAVFormatHeader.nFormatTag == WAVE_FORMAT_IEEE_FLOAT)
            return APE_ERROR_INVALID_INPUT_FILE;
    #endif

    // if the format is an odd bits per sample, just update to a known number -- decoding stores the header so will still be correct (and the block align is that size anyway)
    const int nSampleBits = 8 * WAVFormatHeader.nBlockAlign / APE_MAX<int>(1, WAVFormatHeader.nChannels);
    if (nSampleBits > 0)
        WAVFormatHeader.nBitsPerSample = static_cast<uint16>(((WAVFormatHeader.nBitsPerSample + (nSampleBits - 1)) / nSampleBits) * nSampleBits);

    // copy the format information to the WAVEFORMATEX passed in
    FillWaveFormatEx(&m_wfeSource, static_cast<int>(WAVFormatHeader.nFormatTag), static_cast<int>(WAVFormatHeader.nSamplesPerSecond), static_cast<int>(WAVFormatHeader.nBitsPerSample), static_cast<int>(WAVFormatHeader.nChannels));

    // see if we're float
    if (WAVFormatHeader.nFormatTag == WAVE_FORMAT_IEEE_FLOAT)
        m_bFloat = true;

    // skip over any extra data in the header
    if (RIFFChunkHeader.nChunkBytes != static_cast<uint32_t>(-1))
    {
        const int64 nWAVFormatHeaderExtra = static_cast<int64>(RIFFChunkHeader.nChunkBytes) - static_cast<int64>(sizeof(WAVFormatHeader));
        if (nWAVFormatHeaderExtra < 0)
        {
            return APE_ERROR_INVALID_INPUT_FILE;
        }
        else if ((nWAVFormatHeaderExtra > 0) && (nWAVFormatHeaderExtra < APE_BYTES_IN_MEGABYTE))
        {
            // read the extra
            CSmartPtr<unsigned char> spWAVFormatHeaderExtra(nWAVFormatHeaderExtra);
            APE_RETURN_ON_ERROR(ReadSafe(m_spIO, spWAVFormatHeaderExtra, static_cast<int>(nWAVFormatHeaderExtra)))

            // the extra specifies the format and it might not be PCM, so check
            #pragma pack(push, 1)
            struct CWAVFormatExtra
            {
                uint16 cbSize;
                uint16 nValidBitsPerSample;
                uint32 nChannelMask;
                BYTE guidSubFormat[16];
            };
            #pragma pack(pop)

            if (nWAVFormatHeaderExtra >= static_cast<APE::int64>(sizeof(CWAVFormatExtra)))
            {
                CWAVFormatExtra * pExtra = reinterpret_cast<CWAVFormatExtra *>(spWAVFormatHeaderExtra.GetPtr());

                pExtra->cbSize = ConvertU16LE(pExtra->cbSize);
                pExtra->nValidBitsPerSample = ConvertU16LE(pExtra->nValidBitsPerSample);
                pExtra->nChannelMask = ConvertU32LE(pExtra->nChannelMask);

                if (pExtra->cbSize == 22) // this can also be zero in which case there is meaningless data there
                {
                    const BYTE guidPCM[16] = { 1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113 }; // KSDATAFORMAT_SUBTYPE_PCM but that isn't cross-platform
                    const BYTE guidFloat[16] = { 3, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113 }; // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT but that isn't cross-platform
                    if ((memcmp(&pExtra->guidSubFormat, &guidPCM, 16) != 0) &&
                        (memcmp(&pExtra->guidSubFormat, &guidFloat, 16) != 0))
                    {
                        // we're not PCM or float, so error
                        return APE_ERROR_INVALID_INPUT_FILE;
                    }

                    // switch the format to float if we're the float subtype
                    if (memcmp(&pExtra->guidSubFormat, &guidFloat, 16) == 0)
                    {
                        m_bFloat = true;
                    }
                }
                else
                {
                    // size is not the size we understand so don't look at it
                }
            }
        }
    }

    // check that float data is 32-bits per sample (we found files where this was not true and accepted them for a while, but now reject them like WavPack)
    // files that are 64-bit double hit this code so it's proper to reject the files
    if (m_bFloat && (WAVFormatHeader.nBitsPerSample != 32))
        return APE_ERROR_INVALID_INPUT_FILE;

    // find the data chunk
    APE_RETURN_ON_ERROR(ReadRIFFHeader(RIFFChunkHeader))

    int64 nDataChunk = -1;
    while (true)
    {
        // check for chunks that go past the end of the file
        if ((m_nFileBytes != APE_FILE_SIZE_UNDEFINED) && (RIFFChunkHeader.nChunkBytes != static_cast<uint32_t>(-1)))
        {
            if (RIFFChunkHeader.nChunkBytes > (m_nFileBytes - m_spIO->GetPosition()))
            {
                // just flag the chunk as going to the end of the file (previously we were returning APE_ERROR_INVALID_INPUT_FILE)
                RIFFChunkHeader.nChunkBytes = static_cast<uint32_t>(-1);
            }
        }

        // move the file pointer to the end of this chunk
        if (RIFFChunkHeader.cChunkLabel[0] == 'd' && RIFFChunkHeader.cChunkLabel[1] == 'a' && RIFFChunkHeader.cChunkLabel[2] == 't' && RIFFChunkHeader.cChunkLabel[3] == 'a')
        {
            // found the data chunk
            bool bUnknownLength = (RIFFChunkHeader.nChunkBytes == static_cast<uint32_t>(-1));
            int64 nChunkBytes = RIFFChunkHeader.nChunkBytes;

            // use the DS64 header if we found one
            if (bUnknownLength && (nDS64DataBytes >= 0))
            {
                int64 nDSD64DataBytesBlockAligned = nDS64DataBytes;
                nDSD64DataBytesBlockAligned = (nDSD64DataBytesBlockAligned / static_cast<int64>(m_wfeSource.nBlockAlign)) * static_cast<int64>(m_wfeSource.nBlockAlign);
                nChunkBytes = nDSD64DataBytesBlockAligned;
                bUnknownLength = false;
            }

            m_nDataBytes = bUnknownLength ? static_cast<int64>(-1) : nChunkBytes;

            // see if we're at the end after this and if so just break
            // otherwise store the position for seeking back to the beginning of the data chunk then seek to the next chunk
            int64 nPosition = m_spIO->GetPosition();
            int64 nPositionAfterChunk = nPosition + nChunkBytes;

            // store the header bytes
            m_nHeaderBytes = static_cast<uint32>(nPosition);

            // just quit if we're an unknown length or the chunk is unknown (after setting the header bytes)
            if (bUnknownLength || (m_nFileBytes == APE_FILE_SIZE_UNDEFINED))
                break;

            // check for end or if the next chunk should be read
            if (nPositionAfterChunk >= m_nFileBytes)
            {
                // we're at the end after this, so just break the loop
                break;
            }
            else
            {
                // store the position to seek back to then skip this chunk and go onto the next
                nDataChunk = nPosition;
                m_spIO->Seek(nChunkBytes, SeekFileCurrent);
            }
        }
        else if ((RIFFChunkHeader.cChunkLabel[0] == 'i' && RIFFChunkHeader.cChunkLabel[1] == 'd' && RIFFChunkHeader.cChunkLabel[2] == '3' && RIFFChunkHeader.cChunkLabel[3] == ' ') ||
            (RIFFChunkHeader.cChunkLabel[0] == 'I' && RIFFChunkHeader.cChunkLabel[1] == 'D' && RIFFChunkHeader.cChunkLabel[2] == '3' && RIFFChunkHeader.cChunkLabel[3] == ' '))
        {
            // read the tag
            int nTagBytes = static_cast<int>(RIFFChunkHeader.nChunkBytes);
            CSmartPtr<unsigned char> spTag(nTagBytes);
            APE_RETURN_ON_ERROR(ReadSafe(m_spIO, spTag, nTagBytes))

            // analyze the tag data
            if (m_pTag != APE_NULL)
                m_pTag->Analyze(spTag, nTagBytes);
        }
        else
        {
            // read to the next chunk since read works and seek doesn't for the header reader
            CSmartPtr<unsigned char> spRIFFChunk(new unsigned char [RIFFChunkHeader.nChunkBytes], true);
            APE_RETURN_ON_ERROR(ReadSafe(m_spIO, spRIFFChunk, static_cast<int>(RIFFChunkHeader.nChunkBytes)))
        }

        // decide if we want to loop more to keep searching
        bool bAgain = false;
        if (m_nFileBytes == APE_FILE_SIZE_UNDEFINED)
        {
            // keep reading and we'll break once we read the data chunk
            bAgain = true;
        }
        else
        {
            // see if we have enough data for the chunk header
            if (static_cast<size_t>(m_nFileBytes - m_spIO->GetPosition()) > sizeof(RIFFChunkHeader))
                bAgain = true;

            // no need to loop if we've found the tag and the data chunk
            if (bAgain && (m_nDataBytes > 0) && ((m_pTag == APE_NULL) || (m_pTag->m_bFoundTag != false)))
                bAgain = false;
        }

        // quit the loop if we decided to above
        if (bAgain == false)
            break;

        // read the next chunk then loop
        APE_RETURN_ON_ERROR(ReadRIFFHeader(RIFFChunkHeader))
    }

    // seek to the start of the data
    if (nDataChunk != -1)
        m_spIO->Seek(nDataChunk, SeekFileBegin);

    // if we didn't find a data block, reject the file
    if (m_nDataBytes == 0)
        return APE_ERROR_INVALID_INPUT_FILE;

    if (m_nDataBytes == -1)
    {
        // handle unknown length data blocks
        if (m_nFileBytes == -1)
        {
            m_nDataBytes = -1;
        }
        else
        {
            m_nDataBytes = m_nFileBytes - m_nHeaderBytes;
            m_nDataBytes = (m_nDataBytes / m_wfeSource.nBlockAlign) * m_wfeSource.nBlockAlign; // block align
        }
    }
    else if (m_nDataBytes > (m_nFileBytes - m_nHeaderBytes))
    {
        // handle data blocks that are bigger than the file
        m_nDataBytes = m_nFileBytes - m_nHeaderBytes;
        m_nDataBytes = (m_nDataBytes / m_wfeSource.nBlockAlign) * m_wfeSource.nBlockAlign; // block align
    }

    // make sure the data bytes is a whole number of blocks
    if ((m_nDataBytes != -1) && ((m_nDataBytes % m_wfeSource.nBlockAlign) != 0))
    {
        // we used to return APE_ERROR_INVALID_INPUT_FILE, but on 9/30/2026 this was changed to just shrink the number of data bytes
        // any extra bytes will get encoded as terminating data, so it should remain bit perfect

        // just shrink the number of data bytes
        m_nDataBytes = (m_nDataBytes / m_wfeSource.nBlockAlign) * m_wfeSource.nBlockAlign;
    }

    // calculate the terminating bytes
    m_nTerminatingBytes = static_cast<uint32_t>(m_nFileBytes - m_nDataBytes - m_nHeaderBytes);

    // no terminating data if we're unknown length (like a pipe) since seeking to read it would fail
    if (m_bUnknownLengthFile)
        m_nTerminatingBytes = 0;

    // we made it this far, everything must be cool
    return APE_ERROR_SUCCESS;
}

int CWAVInputSource::ReadRIFFHeader(RIFF_CHUNK_HEADER & RIFFChunkHeader)
{
    // find the data chunk
    APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &RIFFChunkHeader, sizeof(RIFFChunkHeader)))
    RIFFChunkHeader.nChunkBytes = ConvertU32LE(RIFFChunkHeader.nChunkBytes);
    if (RIFFChunkHeader.nChunkBytes != static_cast<uint32_t>(-1))
        RIFFChunkHeader.nChunkBytes = APE_ALIGN_2_BYTE(RIFFChunkHeader.nChunkBytes); // RIFF chunks must be 2-byte aligned, so pad with an extra byte when necessary
    return APE_ERROR_SUCCESS;
}

int CWAVInputSource::GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved)
{
    if (!m_bIsValid) return APE_ERROR_UNDEFINED;

    const int nBytes = (m_wfeSource.nBlockAlign * nBlocks);
    int64 nBytesRead = 0;

    const int nReadResult = m_spIO->Read(pBuffer, nBytes, &nBytesRead);
    if (nReadResult != APE_ERROR_SUCCESS)
        return nReadResult;

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    if (m_wfeSource.wBitsPerSample >= 16)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#endif

    if (pBlocksRetrieved) *pBlocksRetrieved = static_cast<int>(nBytesRead / m_wfeSource.nBlockAlign);

    return APE_ERROR_SUCCESS;
}

int CWAVInputSource::GetHeaderData(unsigned char * pBuffer)
{
    if (!m_bIsValid) return APE_ERROR_UNDEFINED;

    int nResult = APE_ERROR_SUCCESS;

    if (m_nHeaderBytes > 0)
    {
        int nFileBufferBytes = static_cast<int>(m_nHeaderBytes);
        const unsigned char * pFileBuffer = m_spIO->GetBuffer(&nFileBufferBytes);
        if (pFileBuffer != APE_NULL)
        {
            // we have the data already cached, so no need to seek and read
            memcpy(pBuffer, pFileBuffer, APE_MIN(static_cast<size_t>(m_nHeaderBytes), static_cast<size_t>(nFileBufferBytes)));
        }
        else
        {
            // use the base class
            nResult = GetHeaderDataHelper(m_bIsValid, pBuffer, m_nHeaderBytes, m_spIO);
        }
    }

    return nResult;
}

int CWAVInputSource::GetTerminatingData(unsigned char * pBuffer)
{
    return GetTerminatingDataHelper(m_bIsValid, pBuffer, m_nTerminatingBytes, m_spIO);
}

/**************************************************************************************************
CAIFFInputSource - wraps working with AIFF files
**************************************************************************************************/
/*static*/ bool CAIFFInputSource::GetHeaderMatches(BYTE aryHeader[64])
{
    bool bMatch = (aryHeader[0] == 'F' && aryHeader[1] == 'O' && aryHeader[2] == 'R' && aryHeader[3] == 'M');
    if (bMatch)
    {
        if ((aryHeader[8] == 'A') && (aryHeader[9] == 'I') && (aryHeader[10] == 'F') && (aryHeader[11] == 'F'))
        {
            // AIFF
        }
        else if ((aryHeader[8] == 'A') && (aryHeader[9] == 'I') && (aryHeader[10] == 'F') && (aryHeader[11] == 'C'))
        {
            // AIFC
        }
        else
        {
            // unknown
            bMatch = false;
        }
    }
    return bMatch;
}

CAIFFInputSource::CAIFFInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, IID3v2Tag * pTag, int * pErrorCode)
{
    m_bIsValid = false;
    m_nDataBytes = 0;
    m_nFileBytes = 0;
    m_nHeaderBytes = 0;
    m_nTerminatingBytes = 0;
    m_bLittleEndian = false;
    m_bFloat = false;
    m_bSigned8Bit = true;
    m_pTag = pTag;

    if (pIO == APE_NULL || pwfeSource == APE_NULL)
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_BAD_PARAMETER;
        return;
    }

    m_spIO.Assign(pIO);

    int nResult = AnalyzeSource();
    if ((nResult == APE_ERROR_SUCCESS) && (m_wfeSource.nBlockAlign > 0))
    {
        // fill in the parameters
        if (pwfeSource) memcpy(pwfeSource, &m_wfeSource, sizeof(WAVEFORMATEX));
        if (pTotalBlocks) *pTotalBlocks = m_nDataBytes / static_cast<int64>(m_wfeSource.nBlockAlign);
        if (pHeaderBytes) *pHeaderBytes = m_nHeaderBytes;
        if (pTerminatingBytes) *pTerminatingBytes = m_nTerminatingBytes;

        m_bIsValid = true;
    }

    if (pErrorCode) *pErrorCode = nResult;
}

CAIFFInputSource::~CAIFFInputSource()
{
}

int CAIFFInputSource::AnalyzeSource()
{
    // analyze AIFF header
    //
    // header has 54 bytes
    //    FORM                        - 4 bytes       "FORM"
    //      Size                      - 4             size of all data, excluding the top 8 bytes
    //      AIFF                      - 4             "AIFF"
    //        COMM                    - 4             "COMM"
    //          size                  - 4             size of COMM chunk excluding the 8 bytes for "COMM" and size, should be 18
    //            Channels            - 2             number of channels
    //            sampleFrames        - 4             number of frames
    //            sampleSize          - 2             size of each sample
    //            sampleRate          - 10            samples per second
    //        SSND                    - 4             "SSND"
    //          size                  - 4             size of all data in the chunk, excluding "SSND" and size field
    //            BlockAlign          - 4             normally set to 0
    //            Offset              - 4             normally set to 0
    //            Audio data follows

    // get the file size
    m_nFileBytes = m_spIO->GetSize();

    // get the RIFF header
    CInputSource::RIFF_HEADER RIFFHeader;
    APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &RIFFHeader, sizeof(RIFFHeader)))
    RIFFHeader.nBytes = ConvertU32BE(RIFFHeader.nBytes);

    // make sure the RIFF header is valid
    if (memcmp(RIFFHeader.cRIFF, "FORM", 4) != 0)
        return APE_ERROR_INVALID_INPUT_FILE;
    if (static_cast<int64>(RIFFHeader.nBytes) != (m_nFileBytes - static_cast<int64>(sizeof(CInputSource::RIFF_HEADER))))
        return APE_ERROR_INVALID_INPUT_FILE;

    // read the AIFF header
    #pragma pack(push, 2)
    struct COMM_HEADER
    {
        int16 nChannels;
        uint32 nFrames;
        int16 nSampleSize;
        uint16 nSampleRateExponent;
        uint64 nSampleRateMantissa;
    };
    #pragma pack(pop)

    // read AIFF header and only support AIFF
    char cAIFF[4] = { 0, 0, 0, 0 };
    APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &cAIFF[0], sizeof(cAIFF)))
    if (memcmp(cAIFF, "AIFF", 4) != 0 &&
        memcmp(cAIFF, "AIFC", 4) != 0)
    {
        // unknown type
        return APE_ERROR_INVALID_INPUT_FILE;
    }

    // read chunks
    #pragma pack(push, 1)
    struct CHUNKS
    {
        char cChunkName[4];
        uint32 nChunkBytes;
    };
    #pragma pack(pop)
    COMM_HEADER Common; APE_CLEAR(Common);
    while (true)
    {
        CHUNKS Chunk; APE_CLEAR(Chunk);
        int64 nBytesLeft = m_nFileBytes - m_spIO->GetPosition();
        if (nBytesLeft < static_cast<int64>(sizeof(Chunk)))
            break;
        APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &Chunk, sizeof(Chunk)))
        Chunk.nChunkBytes = ConvertU32BE(Chunk.nChunkBytes);
        Chunk.nChunkBytes = (Chunk.nChunkBytes + 1) & static_cast<uint32_t>(~1L);
        bool bSeekToNextChunk = true;

        if (memcmp(Chunk.cChunkName, "COMM", 4) == 0)
        {
            // read the common chunk

            // check the size
            if (sizeof(Common) > Chunk.nChunkBytes)
                return APE_ERROR_INVALID_INPUT_FILE;
            APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &Common, sizeof(Common)))
            bSeekToNextChunk = false; // don't seek since we already read

            Common.nChannels = ConvertI16BE(Common.nChannels);
            Common.nFrames = ConvertU32BE(Common.nFrames);
            Common.nSampleSize = ConvertI16BE(Common.nSampleSize);
            Common.nSampleRateExponent = ConvertU16BE(Common.nSampleRateExponent);
            Common.nSampleRateMantissa = ConvertU64BE(Common.nSampleRateMantissa);
            const double dSampleRate = GetExtendedDouble(Common.nSampleRateExponent, Common.nSampleRateMantissa);
            const uint32 nSampleRate = static_cast<uint32>(dSampleRate);
            m_bFloat = false;

            // skip rest of header
            if (Chunk.nChunkBytes > sizeof(Common))
            {
                const int nExtraBytes = static_cast<int>(Chunk.nChunkBytes) - static_cast<int>(sizeof(Common));

                CSmartPtr<BYTE> spBuffer(new BYTE [static_cast<size_t>(nExtraBytes)], true);
                APE_RETURN_ON_ERROR(ReadSafe(m_spIO, spBuffer, nExtraBytes))

                // COMM chunks can optionally have a compression type after the last cExtra parameter and in this case "sowt" mean we're little endian (reversed from normal AIFF)
                m_bLittleEndian = false;
                if (nExtraBytes >= 4)
                {
                    if (memcmp(spBuffer, "NONE", 4) == 0)
                    {
                        // this means we're a supported file
                    }
                    else if (memcmp(spBuffer, "twos", 4) == 0)
                    {
                        // this is the reverse of sowt so the endian is flipped
                        m_bLittleEndian = false;
                    }
                    else if (memcmp(spBuffer, "sowt", 4) == 0)
                    {
                        m_bLittleEndian = true;
                    }
                    else if (memcmp(spBuffer, "raw ", 4) == 0)
                    {
                        m_bSigned8Bit = false;
                    }
                    else if ((memcmp(spBuffer, "fl32", 4) == 0) || (memcmp(spBuffer, "FL32", 4) == 0))
                    {
                        m_bFloat = true;
                        #ifndef APE_SUPPORT_FLOAT_COMPRESSION
                            // 32-bit floating point data (not supported)
                            return APE_ERROR_INVALID_INPUT_FILE;
                        #endif
                    }
                    else
                    {
                        // unknown encoding, so we'll error out
                        return APE_ERROR_INVALID_INPUT_FILE;
                    }
                }
            }

            // copy the format information to the WAVEFORMATEX passed in
            FillWaveFormatEx(&m_wfeSource, m_bFloat ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM, static_cast<int>(nSampleRate), static_cast<int>(Common.nSampleSize), static_cast<int>(Common.nChannels));
        }
        else if (memcmp(Chunk.cChunkName, "SSND", 4) == 0)
        {
            // read the SSND header
            struct SSNDHeader
            {
                uint32 offset;
                uint32 blocksize;
            };
            SSNDHeader Header;
            APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &Header, sizeof(Header)))
            m_nDataBytes = static_cast<int64>(Chunk.nChunkBytes) - 8;

            // check the size
            if ((Common.nFrames > 0) && (static_cast<int64>(m_nDataBytes / Common.nFrames) != static_cast<int64>(Common.nSampleSize * Common.nChannels / 8)))
                return APE_ERROR_INVALID_INPUT_FILE;

            // update the header bytes
            m_nHeaderBytes = static_cast<uint32_t>(m_spIO->GetPosition());

            // seek past the end of the SSND chunk
            bSeekToNextChunk = false;
            m_spIO->Seek(static_cast<int64>(static_cast<size_t>(Chunk.nChunkBytes) - sizeof(Header)), SeekFileCurrent);

            // quit if we're not reading tags or we've already found the tag
            if ((m_pTag == APE_NULL) || (m_pTag->m_bFoundTag != false))
                break;
        }
        else if ((m_pTag != APE_NULL) && (memcmp(Chunk.cChunkName, "ID3 ", 4) == 0))
        {
            // tag
            int nTagBytes = static_cast<int>(Chunk.nChunkBytes);
            CSmartPtr<unsigned char> spTag;
            spTag.AllocateArray(nTagBytes);
            APE_RETURN_ON_ERROR(ReadSafe(m_spIO, spTag.GetPtr(), nTagBytes))

            bSeekToNextChunk = false;

            m_pTag->Analyze(spTag, nTagBytes);

            // quit if we've already found the SSND
            if (m_nDataBytes > 0)
                break;
        }

        if (bSeekToNextChunk)
        {
            const int nNextChunkBytes = static_cast<int>(Chunk.nChunkBytes);
            m_spIO->Seek(nNextChunkBytes, SeekFileCurrent);
        }
    }

    // make sure we found the SSND header
    if (m_nDataBytes <= 0)
        return APE_ERROR_INVALID_INPUT_FILE;

    // calculate the terminating data
    m_nTerminatingBytes = static_cast<uint32_t>(m_nFileBytes - (m_nHeaderBytes + m_nDataBytes));

    // seek back to the start of the data
    m_spIO->Seek(m_nHeaderBytes, SeekFileBegin);

    // we made it this far, everything must be cool
    return APE_ERROR_SUCCESS;
}

int CAIFFInputSource::GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved)
{
    if (!m_bIsValid) return APE_ERROR_UNDEFINED;

    const int nBytes = (m_wfeSource.nBlockAlign * nBlocks);
    int64 nBytesRead = 0;

    if (m_spIO->Read(pBuffer, nBytes, &nBytesRead) != APE_ERROR_SUCCESS)
        return APE_ERROR_IO_READ;

    if (m_wfeSource.wBitsPerSample == 8)
    {
        if (m_bSigned8Bit)
            Convert8BitSignedToUnsigned(pBuffer, m_wfeSource.nChannels, nBlocks);
    }
#if APE_BYTE_ORDER == APE_LITTLE_ENDIAN
    else if (!m_bLittleEndian)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#else
    else if (m_bLittleEndian)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#endif

    if (pBlocksRetrieved) *pBlocksRetrieved = static_cast<int>(nBytesRead / m_wfeSource.nBlockAlign);

    return APE_ERROR_SUCCESS;
}

int CAIFFInputSource::GetHeaderData(unsigned char * pBuffer)
{
    return GetHeaderDataHelper(m_bIsValid, pBuffer, m_nHeaderBytes, m_spIO);
}

int CAIFFInputSource::GetTerminatingData(unsigned char * pBuffer)
{
    return GetTerminatingDataHelper(m_bIsValid, pBuffer, m_nTerminatingBytes, m_spIO);
}

double CAIFFInputSource::GetExtendedDouble(uint16_t nExponent, uint64_t nMantissa)
{
    // this code is borrowed from David Bryant's WavPack
    // he said it derives from this:
    // https://en.wikipedia.org/wiki/Extended_precision#x86_extended_precision_format
    // there's also code here:
    // https://stackoverflow.com/questions/2963055/convert-extended-precision-float-80-bit-to-double-64-bit-in-msvc

    const double dSign = (nExponent & 0x8000) ? -1.0 : 1.0, dValue = static_cast<double>(nMantissa);
    const double dScaler = pow(2.0, static_cast<double>(nExponent & 0x7fff) - 16446);
    const double dResult = dValue * dScaler * dSign;
    return dResult;
}

bool CAIFFInputSource::GetIsBigEndian() const
{
    return !m_bLittleEndian;
}

bool CAIFFInputSource::GetIsSigned8Bit() const
{
    return m_bSigned8Bit;
}

/**************************************************************************************************
CW64InputSource - wraps working with W64 files
**************************************************************************************************/
struct CW64InputSource::W64ChunkHeader
{
    GUID guidIdentifier; // the identifier of the chunk
    uint64 nBytes; // the size of the chunk
};

struct CW64InputSource::WAVFormatChunkData
{
    uint16            nFormatTag;                // the format of the WAV...should equal 1 for a PCM file
    uint16            nChannels;                 // the number of channels
    uint32            nSamplesPerSecond;         // the number of samples per second
    uint32            nAverageBytesPerSecond;    // the bytes per second
    uint16            nBlockAlign;               // block alignment
    uint16            nBitsPerSample;            // the number of bits per sample
};

/*static*/ bool CW64InputSource::GetHeaderMatches(BYTE aryHeader[64])
{
    static const GUID guidRIFF = { ConvertU32LE(0x66666972), ConvertU16LE(0x912E), ConvertU16LE(0x11CF), { 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00 } };
    static const GUID guidWAVE = { ConvertU32LE(0x65766177), ConvertU16LE(0xACF3), ConvertU16LE(0x11D3), { 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A } };
    bool bW64 = (memcmp(aryHeader, &guidRIFF, sizeof(guidRIFF)) == 0);
    if (bW64)
    {
        if (memcmp(&aryHeader[24], &guidWAVE, sizeof(GUID)) != 0)
        {
            bW64 = false;
        }
    }

    return bW64;
}

CW64InputSource::CW64InputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int * pErrorCode)
{
    m_bIsValid = false;
    m_bFloat = false;
    m_nDataBytes = 0;
    m_nFileBytes = 0;
    m_nHeaderBytes = 0;
    m_nTerminatingBytes = 0;

    if ((pIO == APE_NULL) || (pwfeSource == APE_NULL))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_BAD_PARAMETER;
        return;
    }

    m_spIO.Assign(pIO);

    int nResult = AnalyzeSource();
    if ((nResult == APE_ERROR_SUCCESS) && (m_wfeSource.nBlockAlign > 0))
    {
        // fill in the parameters
        if (pwfeSource) memcpy(pwfeSource, &m_wfeSource, sizeof(WAVEFORMATEX));
        if (pTotalBlocks) *pTotalBlocks = m_nDataBytes / static_cast<int64>(m_wfeSource.nBlockAlign);
        if (pHeaderBytes) *pHeaderBytes = m_nHeaderBytes;
        if (pTerminatingBytes) *pTerminatingBytes = m_nTerminatingBytes;

        m_bIsValid = true;
    }

    if (pErrorCode) *pErrorCode = nResult;
}

CW64InputSource::~CW64InputSource()
{
}

int CW64InputSource::AnalyzeSource()
{
    // chunk identifiers
    static const GUID guidRIFF = { ConvertU32LE(0x66666972), ConvertU16LE(0x912E), ConvertU16LE(0x11CF), { 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00 } };
    static const GUID guidWAVE = { ConvertU32LE(0x65766177), ConvertU16LE(0xACF3), ConvertU16LE(0x11D3), { 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A } };
    static const GUID guidDATA = { ConvertU32LE(0x61746164), ConvertU16LE(0xACF3), ConvertU16LE(0x11D3), { 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A } };
    static const GUID guidFMT = { ConvertU32LE(0x20746D66), ConvertU16LE(0xACF3), ConvertU16LE(0x11D3), { 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A } };
    const bool bReadMetadataChunks = false;

    // read the riff header
    bool bDataChunkRead = false;
    bool bFormatChunkRead = false;
    W64ChunkHeader RIFFHeader;
    int64 nBytesRead = 0;
    m_nFileBytes = m_spIO->GetSize();

    m_spIO->Read(&RIFFHeader, sizeof(RIFFHeader), &nBytesRead);

    RIFFHeader.nBytes = ConvertU64LE(RIFFHeader.nBytes);
    RIFFHeader.nBytes = APE_ALIGN_8_BYTE(RIFFHeader.nBytes);

    if ((memcmp(&RIFFHeader.guidIdentifier, &guidRIFF, sizeof(GUID)) == 0) && (RIFFHeader.nBytes == static_cast<uint64>(m_nFileBytes)))
    {
        // read and verify the wave data type header
        GUID DataHeader;
        const int64 nDataHeaderSize = sizeof(DataHeader);
        m_spIO->Read(&DataHeader, nDataHeaderSize, &nBytesRead);
        if (memcmp(&DataHeader, &guidWAVE, sizeof(GUID)) == 0)
        {
            // for now, we only need to process these two chunks besides 'fmt ' chunk above -
            // "data", and "id3 "/"tag "
            while (1)
            {
                // read chunks one by one
                W64ChunkHeader Header;
                m_spIO->Read(&Header, sizeof(Header), &nBytesRead);

                // perhaps we have reached EOF
                if (nBytesRead < static_cast<int64>(sizeof(Header)))
                    break;

                Header.nBytes = ConvertU64LE(Header.nBytes);
                Header.nBytes = APE_ALIGN_8_BYTE(Header.nBytes);

                // get / check chunk size
                const int64 nChunkRemainingBytes = static_cast<int64>(Header.nBytes) - static_cast<int64>(sizeof(Header));
                if ((m_spIO->GetPosition() + nChunkRemainingBytes) > m_nFileBytes)
                    break;

                // switched based on the chunk type
                if ((memcmp(&Header.guidIdentifier, &guidFMT, sizeof(GUID)) == 0) &&
                    (nChunkRemainingBytes >= static_cast<APE::int64>(sizeof(WAVFormatChunkData))))
                {
                    // read data
                    WAVFormatChunkData Data;
                    m_spIO->Read(&Data, sizeof(Data), &nBytesRead);
                    if (nBytesRead != sizeof(Data))
                        break;

                    Data.nFormatTag = ConvertU16LE(Data.nFormatTag);
                    Data.nChannels = ConvertU16LE(Data.nChannels);
                    Data.nSamplesPerSecond = ConvertU32LE(Data.nSamplesPerSecond);
                    Data.nAverageBytesPerSecond = ConvertU32LE(Data.nAverageBytesPerSecond);
                    Data.nBlockAlign = ConvertU16LE(Data.nBlockAlign);
                    Data.nBitsPerSample = ConvertU16LE(Data.nBitsPerSample);

                    // skip the rest
                    m_spIO->Seek(Align(nChunkRemainingBytes, 8) - static_cast<int64>(sizeof(Data)), SeekFileCurrent);

                    // verify the format (must be WAVE_FORMAT_PCM or WAVE_FORMAT_EXTENSIBLE)
                    m_bFloat = false;
                    if (Data.nFormatTag == WAVE_FORMAT_IEEE_FLOAT)
                    {
                        #ifndef APE_SUPPORT_FLOAT_COMPRESSION
                            break;
                        #endif
                        m_bFloat = true;
                    }
                    else if ((Data.nFormatTag != WAVE_FORMAT_PCM) && (Data.nFormatTag != WAVE_FORMAT_EXTENSIBLE))
                    {
                        break;
                    }

                    // copy information over for internal storage
                    // may want to error check this header (bad avg bytes per sec, bad format, bad block align, etc...)
                    FillWaveFormatEx(&m_wfeSource, m_bFloat ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM, static_cast<int>(Data.nSamplesPerSecond), static_cast<int>(Data.nBitsPerSample), static_cast<int>(Data.nChannels));

                    m_wfeSource.nAvgBytesPerSec = Data.nAverageBytesPerSecond;
                    m_wfeSource.nBlockAlign = Data.nBlockAlign;

                    bFormatChunkRead = true;

                    // short circuit if we don't need metadata
                    if (!bReadMetadataChunks && (bFormatChunkRead && bDataChunkRead))
                        break;
                }
                else if (memcmp(&Header.guidIdentifier, &guidDATA, sizeof(GUID)) == 0)
                {
                    // 'data' chunk

                    // fill in the data bytes (the length of the 'data' chunk)
                    m_nDataBytes = nChunkRemainingBytes;
                    m_nHeaderBytes = static_cast<uint32_t>(m_spIO->GetPosition());

                    bDataChunkRead = true;

                    // short circuit if we don't need metadata
                    if (!bReadMetadataChunks && (bFormatChunkRead && bDataChunkRead))
                        break;

                    // move to the end of WAVEFORM data, so we can read other chunks behind it (if necessary)
                    m_spIO->Seek(Align(nChunkRemainingBytes, 8), SeekFileCurrent);
                }
                else
                {
                    m_spIO->Seek(Align(nChunkRemainingBytes, 8), SeekFileCurrent);
                }
            }
        }
    }

    // we must read both the data and format chunks
    if (bDataChunkRead && bFormatChunkRead)
    {
        // should error check this maybe
        m_nDataBytes = APE_MIN(m_nDataBytes, m_nFileBytes - m_nHeaderBytes);

        // get terminating bytes
        m_nTerminatingBytes = static_cast<uint32_t>(m_nFileBytes - m_nDataBytes - m_nHeaderBytes);

        // we're valid if we make it this far
        m_bIsValid = true;
    }

    // we made it this far, everything must be cool
    return m_bIsValid ? APE_ERROR_SUCCESS : APE_ERROR_INVALID_INPUT_FILE;
}

int CW64InputSource::GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved)
{
    if (!m_bIsValid) return APE_ERROR_UNDEFINED;

    const int64 nBytes = static_cast<int64>(m_wfeSource.nBlockAlign) * static_cast<int64>(nBlocks);
    int64 nBytesRead = 0;

    if (m_spIO->Read(pBuffer, nBytes, &nBytesRead) != APE_ERROR_SUCCESS)
        return APE_ERROR_IO_READ;

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    if (m_wfeSource.wBitsPerSample >= 16)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#endif

    if (pBlocksRetrieved) *pBlocksRetrieved = static_cast<int>(nBytesRead / m_wfeSource.nBlockAlign);

    return APE_ERROR_SUCCESS;
}

int CW64InputSource::GetHeaderData(unsigned char * pBuffer)
{
    return GetHeaderDataHelper(m_bIsValid, pBuffer, m_nHeaderBytes, m_spIO);
}

int CW64InputSource::GetTerminatingData(unsigned char * pBuffer)
{
    return GetTerminatingDataHelper(m_bIsValid, pBuffer, m_nTerminatingBytes, m_spIO);
}

int64 CW64InputSource::Align(int64 nValue, int nAlignment)
{
    ASSERT(nAlignment > 0 && ((nAlignment & (nAlignment - 1)) == 0));
    return (nValue + nAlignment - 1) & ~((static_cast<int64>(nAlignment) - 1));
}

/**************************************************************************************************
CSNDInputSource - wraps working with SND files
**************************************************************************************************/
/*static*/ bool CSNDInputSource::GetHeaderMatches(BYTE aryHeader[64])
{
    if (memcmp(&aryHeader[0], "dns.", 4) == 0)
    {
        return true;
    }
    else if (memcmp(&aryHeader[0], ".snd", 4) == 0)
    {
        return true;
    }

    return false;
}

CSNDInputSource::CSNDInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int * pErrorCode, int32 * pFlags)
{
    m_bIsValid = false;
    m_nDataBytes = 0;
    m_nFileBytes = 0;
    m_nHeaderBytes = 0;
    m_nTerminatingBytes = 0;
    m_bBigEndian = false;

    if (pIO == APE_NULL || pwfeSource == APE_NULL)
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_BAD_PARAMETER;
        return;
    }

    m_spIO.Assign(pIO);

    int nResult = AnalyzeSource(pFlags);
    if ((nResult == APE_ERROR_SUCCESS) && (m_wfeSource.nBlockAlign > 0))
    {
        // fill in the parameters
        if (pwfeSource) memcpy(pwfeSource, &m_wfeSource, sizeof(WAVEFORMATEX));
        if (pTotalBlocks) *pTotalBlocks = m_nDataBytes / static_cast<int64>(m_wfeSource.nBlockAlign);
        if (pHeaderBytes) *pHeaderBytes = m_nHeaderBytes;
        if (pTerminatingBytes) *pTerminatingBytes = m_nTerminatingBytes;

        m_bIsValid = true;
    }

    if (pErrorCode) *pErrorCode = nResult;
}

CSNDInputSource::~CSNDInputSource()
{
}

int CSNDInputSource::AnalyzeSource(int32 * pFlags)
{
    bool bIsValid = false;
    bool bSupportedFormat = false;

    // get the file size (may want to error check this for files over 2 GB)
    m_nFileBytes = m_spIO->GetSize();

    // read the AU header
    class CAUHeader
    {
    public:
        uint32_t m_nMagicNumber;
        uint32_t m_nDataOffset;
        uint32_t m_nDataSize;
        uint32_t m_nEncoding;
        uint32_t m_nSampleRate;
        uint32_t m_nChannels;
    };
    CAUHeader Header; APE_CLEAR(Header);
    int64 nBytesRead = 0;
    if ((m_spIO->Read(&Header, sizeof(Header), &nBytesRead) == APE_ERROR_SUCCESS) &&
        (nBytesRead == sizeof(Header)))
    {
        bool bMagicNumberValid = false;
        if (memcmp(&Header.m_nMagicNumber, "dns.", 4) == 0)
        {
            // little-endian
            bMagicNumberValid = true;
            Header.m_nDataOffset = ConvertU32LE(Header.m_nDataOffset);
            Header.m_nDataSize = ConvertU32LE(Header.m_nDataSize);
            Header.m_nEncoding = ConvertU32LE(Header.m_nEncoding);
            Header.m_nSampleRate = ConvertU32LE(Header.m_nSampleRate);
            Header.m_nChannels = ConvertU32LE(Header.m_nChannels);
        }
        else if (memcmp(&Header.m_nMagicNumber, ".snd", 4) == 0)
        {
            // big-endian
            bMagicNumberValid = true;
            m_bBigEndian = true;
            Header.m_nDataOffset = ConvertU32BE(Header.m_nDataOffset);
            Header.m_nDataSize = ConvertU32BE(Header.m_nDataSize);
            Header.m_nEncoding = ConvertU32BE(Header.m_nEncoding);
            Header.m_nSampleRate = ConvertU32BE(Header.m_nSampleRate);
            Header.m_nChannels = ConvertU32BE(Header.m_nChannels);
        }

        if (bMagicNumberValid &&
            (Header.m_nDataOffset >= sizeof(Header)) &&
            (Header.m_nDataOffset < m_nFileBytes))
        {
            // get sizes
            m_nHeaderBytes = Header.m_nDataOffset;
            m_nDataBytes = m_nFileBytes - m_nHeaderBytes;
            if (Header.m_nDataSize > 0)
                m_nDataBytes = APE_MIN<int64>(Header.m_nDataSize, m_nDataBytes);
            m_nTerminatingBytes = static_cast<uint32>(m_nFileBytes - m_nHeaderBytes - m_nDataBytes);

            // set format
            if (Header.m_nEncoding == 1)
            {
                // 8-bit mulaw
                // not supported
            }
            else if (Header.m_nEncoding == 2)
            {
                // 8-bit PCM (signed)
                FillWaveFormatEx(&m_wfeSource, WAVE_FORMAT_PCM, static_cast<int>(Header.m_nSampleRate), 8, static_cast<int>(Header.m_nChannels));
                bSupportedFormat = true;
            }
            else if (Header.m_nEncoding == 3)
            {
                // 16-bit PCM
                FillWaveFormatEx(&m_wfeSource, WAVE_FORMAT_PCM, static_cast<int>(Header.m_nSampleRate), 16, static_cast<int>(Header.m_nChannels));
                bSupportedFormat = true;
            }
            else if (Header.m_nEncoding == 4)
            {
                // 24-bit PCM
                FillWaveFormatEx(&m_wfeSource, WAVE_FORMAT_PCM, static_cast<int>(Header.m_nSampleRate), 24, static_cast<int>(Header.m_nChannels));
                bSupportedFormat = true;
            }
            else if (Header.m_nEncoding == 5)
            {
                // 32-bit PCM
                FillWaveFormatEx(&m_wfeSource, WAVE_FORMAT_PCM, static_cast<int>(Header.m_nSampleRate), 32, static_cast<int>(Header.m_nChannels));
                bSupportedFormat = true;
            }
            else if (Header.m_nEncoding == 6)
            {
                // 32-bit float
                #ifdef APE_SUPPORT_FLOAT_COMPRESSION
                    FillWaveFormatEx(&m_wfeSource, WAVE_FORMAT_IEEE_FLOAT, static_cast<int>(Header.m_nSampleRate), 32, static_cast<int>(Header.m_nChannels));
                    bSupportedFormat = true;
                #else
                    // not supported
                #endif
            }
            else if (Header.m_nEncoding == 7)
            {
                // 64-bit float
                // not supported
            }
            else
            {
                // unsupported format
                ASSERT(false);
            }
        }
        else
        {
            // invalid header
            ASSERT(false);
        }

        // update return value
        if (bSupportedFormat)
            bIsValid = true;
    }

    // seek to the end of the header
    m_spIO->Seek(m_nHeaderBytes, SeekFileBegin);

    // update flags
    *pFlags |= APE_FORMAT_FLAG_SND;
    if (m_bBigEndian)
        *pFlags |= APE_FORMAT_FLAG_BIG_ENDIAN;

    // we made it this far, everything must be cool
    return bIsValid ? APE_ERROR_SUCCESS : APE_ERROR_INVALID_INPUT_FILE;
}

int CSNDInputSource::GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved)
{
    if (!m_bIsValid) return APE_ERROR_UNDEFINED;

    const int64 nBytes = static_cast<int64>(m_wfeSource.nBlockAlign) * static_cast<int64>(nBlocks);
    int64 nBytesRead = 0;

    if (m_spIO->Read(pBuffer, nBytes, &nBytesRead) != APE_ERROR_SUCCESS)
        return APE_ERROR_IO_READ;

    if (m_wfeSource.wBitsPerSample == 8)
        Convert8BitSignedToUnsigned(pBuffer, m_wfeSource.nChannels, nBlocks);
#if APE_BYTE_ORDER == APE_LITTLE_ENDIAN
    else if (m_bBigEndian)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#else
    else if (!m_bBigEndian)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#endif

    if (pBlocksRetrieved) *pBlocksRetrieved = static_cast<int>(nBytesRead / m_wfeSource.nBlockAlign);

    return APE_ERROR_SUCCESS;
}

int CSNDInputSource::GetHeaderData(unsigned char * pBuffer)
{
    return GetHeaderDataHelper(m_bIsValid, pBuffer, m_nHeaderBytes, m_spIO);
}

int CSNDInputSource::GetTerminatingData(unsigned char * pBuffer)
{
    return GetTerminatingDataHelper(m_bIsValid, pBuffer, m_nTerminatingBytes, m_spIO);
}

/**************************************************************************************************
CCAFInputSource - wraps working with CAF files
**************************************************************************************************/
struct CCAFInputSource::CAFFileHeader
{
    char cFileType[4]; // should equal 'caff'
    uint16 mFileVersion;
    uint16 mFileFlags;
};

/*static*/ bool CCAFInputSource::GetHeaderMatches(BYTE aryHeader[64])
{
    CCAFInputSource::CAFFileHeader Header;
    memcpy(&Header, &aryHeader[0], sizeof(CCAFInputSource::CAFFileHeader));
    Header.mFileVersion = static_cast<uint16>(ConvertU16BE(Header.mFileVersion));
    Header.mFileFlags = static_cast<uint16>(ConvertU16BE(Header.mFileFlags));

    if ((Header.cFileType[0] != 'c') ||
        (Header.cFileType[1] != 'a') ||
        (Header.cFileType[2] != 'f') ||
        (Header.cFileType[3] != 'f'))
    {
        return false;
    }

    if (Header.mFileVersion != 1)
    {
        return false;
    }

    return true;
}

CCAFInputSource::CCAFInputSource(IAPEIO * pIO, WAVEFORMATEX * pwfeSource, int64 * pTotalBlocks, int64 * pHeaderBytes, int64 * pTerminatingBytes, int * pErrorCode)
{
    m_bIsValid = false;
    m_nDataBytes = 0;
    m_nFileBytes = 0;
    m_nHeaderBytes = 0;
    m_nTerminatingBytes = 0;
    m_bLittleEndian = false;

    if (pIO == APE_NULL || pwfeSource == APE_NULL)
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_BAD_PARAMETER;
        return;
    }

    m_spIO.Assign(pIO);

    int nResult = AnalyzeSource();
    if ((nResult == APE_ERROR_SUCCESS) && (m_wfeSource.nBlockAlign > 0))
    {
        // fill in the parameters
        if (pwfeSource) memcpy(pwfeSource, &m_wfeSource, sizeof(WAVEFORMATEX));
        if (pTotalBlocks) *pTotalBlocks = m_nDataBytes / static_cast<int64>(m_wfeSource.nBlockAlign);
        if (pHeaderBytes) *pHeaderBytes = m_nHeaderBytes;
        if (pTerminatingBytes) *pTerminatingBytes = m_nTerminatingBytes;

        m_bIsValid = true;
    }

    if (pErrorCode) *pErrorCode = nResult;
}

CCAFInputSource::~CCAFInputSource()
{
}

int CCAFInputSource::AnalyzeSource()
{
    // get the file size
    m_nFileBytes = m_spIO->GetSize();

    // get the header
    CCAFInputSource::CAFFileHeader Header;
    APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &Header, sizeof(Header)))
    Header.mFileVersion = static_cast<uint16>(ConvertU16BE(Header.mFileVersion));
    Header.mFileFlags = static_cast<uint16>(ConvertU16BE(Header.mFileFlags));

    // check the header
    if ((Header.cFileType[0] != 'c') ||
        (Header.cFileType[1] != 'a') ||
        (Header.cFileType[2] != 'f') ||
        (Header.cFileType[3] != 'f'))
    {
        return APE_ERROR_INVALID_INPUT_FILE;
    }

    if (Header.mFileVersion != 1)
    {
        return APE_ERROR_INVALID_INPUT_FILE;
    }

    // read chunks
    #pragma pack(push, 1)
    struct APE_CAFChunkHeader
    {
        char cChunkType[4];
        uint64 mChunkSize;
    };
    struct APE_CAFAudioFormat
    {
        union
        {
            uint64 nSampleRate;
            double dSampleRate;
        };
        char cFormatID[4];
        uint32_t nFormatFlags;
        uint32_t nBytesPerPacket;
        uint32_t nFramesPerPacket;
        uint32_t nChannelsPerFrame;
        uint32_t nBitsPerChannel;
    };
    enum
    {
        APE_kCAFLinearPCMFormatFlagIsFloat = (1L << 0),
        APE_kCAFLinearPCMFormatFlagIsLittleEndian = (1L << 1)
    };
    #pragma pack(pop)

    bool bFoundDesc = false;
    while (true)
    {
        APE_CAFChunkHeader Chunk;
        if (ReadSafe(m_spIO, &Chunk, sizeof(Chunk)) != APE_ERROR_SUCCESS)
            return APE_ERROR_INVALID_INPUT_FILE; // we read past the last chunk and didn't find the necessary chunks

        Chunk.mChunkSize = ConvertU64BE(Chunk.mChunkSize);

        if ((Chunk.cChunkType[0] == 'd') &&
            (Chunk.cChunkType[1] == 'e') &&
            (Chunk.cChunkType[2] == 's') &&
            (Chunk.cChunkType[3] == 'c'))
        {
            if (Chunk.mChunkSize == sizeof(APE_CAFAudioFormat))
            {
                APE_CAFAudioFormat AudioFormat;
                APE_RETURN_ON_ERROR(ReadSafe(m_spIO, &AudioFormat, sizeof(AudioFormat)))

                if ((AudioFormat.cFormatID[0] != 'l') ||
                    (AudioFormat.cFormatID[1] != 'p') ||
                    (AudioFormat.cFormatID[2] != 'c') ||
                    (AudioFormat.cFormatID[3] != 'm'))
                {
                    return APE_ERROR_INVALID_INPUT_FILE;
                }

                AudioFormat.nSampleRate = ConvertU64BE(AudioFormat.nSampleRate);
                AudioFormat.nBitsPerChannel = ConvertU32BE(AudioFormat.nBitsPerChannel);
                AudioFormat.nChannelsPerFrame = ConvertU32BE(AudioFormat.nChannelsPerFrame);
                AudioFormat.nFormatFlags = ConvertU32BE(AudioFormat.nFormatFlags);

                // only support 8-bit, 16-bit, and 24-bit, maybe 32-bit
                bool bFloat = false;
                if (AudioFormat.nBitsPerChannel == 32)
                {
                    if (AudioFormat.nFormatFlags & APE_kCAFLinearPCMFormatFlagIsFloat)
                    {
                        #ifndef APE_SUPPORT_FLOAT_COMPRESSION
                            return APE_ERROR_INVALID_INPUT_FILE;
                        #endif
                        bFloat = true;
                    }
                }
                else if ((AudioFormat.nBitsPerChannel != 8) && (AudioFormat.nBitsPerChannel != 16) && (AudioFormat.nBitsPerChannel != 24))
                {
                    return APE_ERROR_INVALID_INPUT_FILE;
                }

                // if we're little endian, mark that
                if (AudioFormat.nFormatFlags & APE_kCAFLinearPCMFormatFlagIsLittleEndian)
                    m_bLittleEndian = true;

                FillWaveFormatEx(&m_wfeSource, bFloat ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM, static_cast<int>(AudioFormat.dSampleRate), static_cast<int>(AudioFormat.nBitsPerChannel), static_cast<int>(AudioFormat.nChannelsPerFrame));
                bFoundDesc = true;
            }
            else
            {
                return APE_ERROR_INVALID_INPUT_FILE;
            }
        }
        else if ((Chunk.cChunkType[0] == 'd') &&
            (Chunk.cChunkType[1] == 'a') &&
            (Chunk.cChunkType[2] == 't') &&
            (Chunk.cChunkType[3] == 'a'))
        {
            // if we didn't first find the description chunk, fail on this file
            if (bFoundDesc == false)
                return APE_ERROR_INVALID_INPUT_FILE;

            // calculate the header and terminating data
            m_nHeaderBytes = static_cast<uint32>(m_spIO->GetPosition());

            // data bytes are this chunk
            m_nDataBytes = static_cast<int64>(Chunk.mChunkSize);

            // align at the block size
            m_nDataBytes = (m_nDataBytes / m_wfeSource.nBlockAlign) * m_wfeSource.nBlockAlign;

            // terminating bytes are whatever is left
            m_nTerminatingBytes = static_cast<uint32>(m_nFileBytes - (m_nHeaderBytes + m_nDataBytes));

            // we made it this far, everything must be cool
            break;
        }
        else
        {
            // skip this chunk
            m_spIO->Seek(static_cast<int64>(Chunk.mChunkSize), SeekFileCurrent);
        }
    }

    // we made it this far, everything must be cool
    return APE_ERROR_SUCCESS;
}

int CCAFInputSource::GetData(unsigned char * pBuffer, int nBlocks, int * pBlocksRetrieved)
{
    if (!m_bIsValid) return APE_ERROR_UNDEFINED;

    const int64 nBytes = static_cast<int64>(m_wfeSource.nBlockAlign) * static_cast<int64>(nBlocks);
    int64 nBytesRead = 0;

    if (m_spIO->Read(pBuffer, nBytes, &nBytesRead) != APE_ERROR_SUCCESS)
        return APE_ERROR_IO_READ;

    // read data
    if (m_wfeSource.wBitsPerSample == 8)
        Convert8BitSignedToUnsigned(pBuffer, m_wfeSource.nChannels, nBlocks);
#if APE_BYTE_ORDER == APE_LITTLE_ENDIAN
    else if (!m_bLittleEndian)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#else
    else if (m_bLittleEndian)
        SwitchBufferBytes(pBuffer, m_wfeSource.wBitsPerSample / 8, nBlocks * m_wfeSource.nChannels);
#endif

    if (pBlocksRetrieved) *pBlocksRetrieved = static_cast<int>(nBytesRead / m_wfeSource.nBlockAlign);

    return APE_ERROR_SUCCESS;
}

int CCAFInputSource::GetHeaderData(unsigned char * pBuffer)
{
    return GetHeaderDataHelper(m_bIsValid, pBuffer, m_nHeaderBytes, m_spIO);
}

int CCAFInputSource::GetTerminatingData(unsigned char * pBuffer)
{
    return GetTerminatingDataHelper(m_bIsValid, pBuffer, m_nTerminatingBytes, m_spIO);
}

bool CCAFInputSource::GetIsBigEndian() const
{
    return !m_bLittleEndian;
}

}
