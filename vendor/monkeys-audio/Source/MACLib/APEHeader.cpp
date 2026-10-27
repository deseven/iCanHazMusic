#include "All.h"
#include "APEHeader.h"
#include "APEInfo.h"
#include "GlobalFunctions.h"

namespace APE
{

CAPEHeader::CAPEHeader(IAPEIO * pIO)
{
    m_pIO = pIO;
}

CAPEHeader::~CAPEHeader()
{
}

int CAPEHeader::FindDescriptor(bool bSeek)
{
    // store the original location and seek to the beginning
    const int64 nOriginalFileLocation = m_pIO->GetPosition();
    m_pIO->Seek(0, SeekFileBegin);

    // set the default junk bytes to 0
    int nJunkBytes = 0;

    // skip an ID3v2 tag (which we really don't support anyway...)
    int64 nBytesRead = 0;
    unsigned char cID3v2Header[10];
    APE_CLEAR(cID3v2Header);
    m_pIO->Read(cID3v2Header, 10, &nBytesRead);
    if (cID3v2Header[0] == 'I' && cID3v2Header[1] == 'D' && cID3v2Header[2] == '3')
    {
        // why is it so hard to figure the length of an ID3v2 tag ?!?
        unsigned int nSyncSafeLength = 0;
        nSyncSafeLength = static_cast<unsigned int>((cID3v2Header[6] & 127) << 21);
        nSyncSafeLength += static_cast<unsigned int>((cID3v2Header[7] & 127) << 14);
        nSyncSafeLength += static_cast<unsigned int>((cID3v2Header[8] & 127) << 7);
        nSyncSafeLength += static_cast<unsigned int>((cID3v2Header[9] & 127));

        bool bHasTagFooter = false;

        if (cID3v2Header[5] & 16)
        {
            bHasTagFooter = true;
            nJunkBytes = static_cast<int>(nSyncSafeLength + 20);
        }
        else
        {
            nJunkBytes = static_cast<int>(nSyncSafeLength + 10);
        }

        // error check
        if (cID3v2Header[5] & 64)
        {
            // this ID3v2 length calculator algorithm can't cope with extended headers
            // we should be ok though, because the scan for the MAC header below should
            // really do the trick
        }

        m_pIO->Seek(nJunkBytes, SeekFileBegin);

        // scan for padding (slow and stupid, but who cares here...)
        if (!bHasTagFooter)
        {
            char cTemp = 0;
            m_pIO->Read(&cTemp, 1, &nBytesRead);
            while (cTemp == 0 && nBytesRead == 1)
            {
                nJunkBytes++;
                m_pIO->Read(&cTemp, 1, &nBytesRead);
            }
        }
    }

    m_pIO->Seek(nJunkBytes, SeekFileBegin);

    // scan until we hit the APE_DESCRIPTOR, the end of the file, or 1 MB later
    const unsigned int nGoalID1 = ('M' << 24) | ('A' << 16) | ('C' << 8) | (' ');
    const unsigned int nGoalID2 = ('M' << 24) | ('A' << 16) | ('C' << 8) | ('F');
    unsigned int nReadID = 0;
    const int nResult = m_pIO->Read(&nReadID, 4, &nBytesRead);
    if ((nResult != APE_ERROR_SUCCESS) || (nBytesRead != 4)) return APE_ERROR_UNDEFINED;

    nReadID = ConvertU32BE(nReadID);

    nBytesRead = 1;
    int nScanBytes = 0;
    while (((nGoalID1 != nReadID) && (nGoalID2 != nReadID)) && (nBytesRead == 1) && (nScanBytes < (1024 * 1024)))
    {
        unsigned char cTemp = 0;
        m_pIO->Read(&cTemp, 1, &nBytesRead);
        nReadID = (nReadID << 8) | cTemp;
        nJunkBytes++;
        nScanBytes++;
    }

    if ((nGoalID1 != nReadID) && (nGoalID2 != nReadID))
        nJunkBytes = -1;

    // seek to the proper place (depending on result and settings)
    if (bSeek && (nJunkBytes != -1))
    {
        // successfully found the start of the file (seek to it and return)
        m_pIO->Seek(nJunkBytes, SeekFileBegin);
    }
    else
    {
        // restore the original file pointer
        m_pIO->Seek(nOriginalFileLocation, SeekFileBegin);
    }

    return nJunkBytes;
}

void CAPEHeader::Convert32BitSeekTable(APE_FILE_INFO * pInfo, const uint32 * pSeekTable32, int nSeekTableElements)
{
    pInfo->spSeekByteTable64.AllocateArray(nSeekTableElements);
    int64 nSeekAdd = 0;
    uint32 nPrevious = 0;
    for (int z = 0; z < pInfo->nSeekTableElements; z++)
    {
        uint32 nCurrent = ConvertU32LE(pSeekTable32[z]);
        if (nCurrent < nPrevious)
            nSeekAdd += static_cast<int64>(0xFFFFFFFF) + static_cast<int64>(1);

        pInfo->spSeekByteTable64[z] = nSeekAdd + nCurrent;

        nPrevious = nCurrent;
    }
}

int CAPEHeader::Analyze(APE_FILE_INFO * pInfo)
{
    // error check
    if ((m_pIO == APE_NULL) || (pInfo == APE_NULL))
        return APE_ERROR_BAD_PARAMETER;

    // variables
    int64 nBytesRead = 0;

    // find the descriptor
    pInfo->nJunkHeaderBytes = FindDescriptor(true);
    if (pInfo->nJunkHeaderBytes < 0)
        return APE_ERROR_UNDEFINED;

    // read the first 8 bytes of the descriptor (ID and version)
    APE_COMMON_HEADER CommonHeader;
    APE_CLEAR(CommonHeader);
    if ((m_pIO->Read(&CommonHeader, sizeof(APE_COMMON_HEADER), &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != sizeof(APE_COMMON_HEADER)))
        return APE_ERROR_IO_READ;

    CommonHeader.nVersion = ConvertU16LE(CommonHeader.nVersion);

    // make sure we're at the ID
    if ((CommonHeader.cID[0] != 'M' || CommonHeader.cID[1] != 'A' || CommonHeader.cID[2] != 'C' || CommonHeader.cID[3] != ' ') &&
        (CommonHeader.cID[0] != 'M' || CommonHeader.cID[1] != 'A' || CommonHeader.cID[2] != 'C' || CommonHeader.cID[3] != 'F'))
    {
        return APE_ERROR_UNDEFINED;
    }

    int nResult = APE_ERROR_UNDEFINED;

    if (CommonHeader.nVersion >= 3980)
    {
        // current header format
        nResult = AnalyzeCurrent(pInfo);
    }
    else
    {
        // legacy support
        nResult = AnalyzeOld(pInfo);
    }

    // check for invalid channels
    if ((pInfo->nChannels > APE_MAXIMUM_CHANNELS) || (pInfo->nChannels < APE_MINIMUM_CHANNELS))
    {
        return APE_ERROR_INVALID_INPUT_FILE;
    }

    return nResult;
}

int CAPEHeader::AnalyzeCurrent(APE_FILE_INFO * pInfo)
{
    // variable declares
    int64 nBytesRead = 0;
    pInfo->spAPEDescriptor.Assign(new APE_DESCRIPTOR);
    APE_CLEAR(*pInfo->spAPEDescriptor);
    APE_HEADER APEHeader;
    APE_CLEAR(APEHeader);

    // read the descriptor
    m_pIO->Seek(pInfo->nJunkHeaderBytes, SeekFileBegin);
    if ((m_pIO->Read(pInfo->spAPEDescriptor.GetPtr(), sizeof(APE_DESCRIPTOR), &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != sizeof(APE_DESCRIPTOR)))
        return APE_ERROR_IO_READ;

    pInfo->spAPEDescriptor->nVersionEncoder        = ConvertU16LE(pInfo->spAPEDescriptor->nVersionEncoder);
    pInfo->spAPEDescriptor->nVersionProgram        = ConvertU16LE(pInfo->spAPEDescriptor->nVersionProgram);

    pInfo->spAPEDescriptor->nDescriptorBytes       = ConvertU32LE(pInfo->spAPEDescriptor->nDescriptorBytes);
    pInfo->spAPEDescriptor->nHeaderBytes           = ConvertU32LE(pInfo->spAPEDescriptor->nHeaderBytes);
    pInfo->spAPEDescriptor->nSeekTableBytes        = ConvertU32LE(pInfo->spAPEDescriptor->nSeekTableBytes);
    pInfo->spAPEDescriptor->nHeaderDataBytes       = ConvertU32LE(pInfo->spAPEDescriptor->nHeaderDataBytes);
    pInfo->spAPEDescriptor->nAPEFrameDataBytes     = ConvertU32LE(pInfo->spAPEDescriptor->nAPEFrameDataBytes);
    pInfo->spAPEDescriptor->nAPEFrameDataBytesHigh = ConvertU32LE(pInfo->spAPEDescriptor->nAPEFrameDataBytesHigh);
    pInfo->spAPEDescriptor->nTerminatingDataBytes  = ConvertU32LE(pInfo->spAPEDescriptor->nTerminatingDataBytes);

    if ((pInfo->spAPEDescriptor->nDescriptorBytes - nBytesRead) > 0)
    {
        m_pIO->Seek(static_cast<int64>(pInfo->spAPEDescriptor->nDescriptorBytes) - static_cast<int64>(nBytesRead), SeekFileCurrent);
    }

    // read the header
    if ((m_pIO->Read(&APEHeader, sizeof(APEHeader), &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != sizeof(APEHeader)))
        return APE_ERROR_IO_READ;

    APEHeader.nCompressionLevel = ConvertU16LE(APEHeader.nCompressionLevel);
    APEHeader.nFormatFlags      = ConvertU16LE(APEHeader.nFormatFlags);

    APEHeader.nBlocksPerFrame   = ConvertU32LE(APEHeader.nBlocksPerFrame);
    APEHeader.nFinalFrameBlocks = ConvertU32LE(APEHeader.nFinalFrameBlocks);
    APEHeader.nTotalFrames      = ConvertU32LE(APEHeader.nTotalFrames);

    APEHeader.nBitsPerSample    = ConvertU16LE(APEHeader.nBitsPerSample);
    APEHeader.nChannels         = ConvertU16LE(APEHeader.nChannels);
    APEHeader.nSampleRate       = ConvertU16LE(APEHeader.nSampleRate);

    if ((pInfo->spAPEDescriptor->nHeaderBytes - nBytesRead) > 0)
    {
        m_pIO->Seek(static_cast<int64>(pInfo->spAPEDescriptor->nHeaderBytes) - static_cast<int64>(nBytesRead), SeekFileCurrent);
    }

    // fill the APE info structure
    pInfo->nVersionEncoder        = static_cast<int>(pInfo->spAPEDescriptor->nVersionEncoder);
    pInfo->nVersionProgram        = static_cast<int>(pInfo->spAPEDescriptor->nVersionProgram);
    pInfo->nCompressionLevel      = static_cast<int>(APEHeader.nCompressionLevel);
    pInfo->nFormatFlags           = static_cast<int>(APEHeader.nFormatFlags);
    pInfo->nTotalFrames           = static_cast<uint32>(APEHeader.nTotalFrames);
    pInfo->nFinalFrameBlocks      = static_cast<uint32>(APEHeader.nFinalFrameBlocks);
    pInfo->nBlocksPerFrame        = static_cast<uint32>(APEHeader.nBlocksPerFrame);
    pInfo->nChannels              = static_cast<int>(APEHeader.nChannels);
    pInfo->nSampleRate            = static_cast<int>(APEHeader.nSampleRate);
    pInfo->nBitsPerSample         = static_cast<int>(APEHeader.nBitsPerSample);
    pInfo->nBytesPerSample        = pInfo->nBitsPerSample / 8;
    pInfo->nBlockAlign            = pInfo->nBytesPerSample * pInfo->nChannels;
    pInfo->nTotalBlocks           = (APEHeader.nTotalFrames == 0) ? 0 : (static_cast<int64>(APEHeader.nTotalFrames -  1) * static_cast<int64>(pInfo->nBlocksPerFrame)) + static_cast<int64>(APEHeader.nFinalFrameBlocks);

    // WAV data
    pInfo->nWAVDataBytes = static_cast<int64>(pInfo->nTotalBlocks) * static_cast<int64>(pInfo->nBlockAlign);

    // WAV header and footer
    int nWAVHeaderSize = sizeof(WAVE_HEADER);
    if (pInfo->nWAVDataBytes >= (APE_BYTES_IN_GIGABYTE * 4))
        nWAVHeaderSize = sizeof(RF64_HEADER);
    pInfo->nWAVHeaderBytes = (APEHeader.nFormatFlags & APE_FORMAT_FLAG_CREATE_WAV_HEADER) ? nWAVHeaderSize : pInfo->spAPEDescriptor->nHeaderDataBytes;
    pInfo->nWAVTerminatingBytes = pInfo->spAPEDescriptor->nTerminatingDataBytes;

    // WAV total
    pInfo->nWAVTotalBytes = pInfo->nWAVDataBytes + pInfo->nWAVHeaderBytes + pInfo->nWAVTerminatingBytes;

    // APE size
    pInfo->nAPETotalBytes = m_pIO->GetSize();

    // more information
    pInfo->nLengthMS              = static_cast<int>((static_cast<double>(pInfo->nTotalBlocks) * static_cast<double>(1000)) / static_cast<double>(pInfo->nSampleRate));
    pInfo->nAverageBitrate        = (pInfo->nLengthMS <= 0) ? 0 : static_cast<int>((static_cast<double>(pInfo->nAPETotalBytes) * static_cast<double>(8)) / static_cast<double>(pInfo->nLengthMS));
    pInfo->nDecompressedBitrate   = (pInfo->nBlockAlign * pInfo->nSampleRate * 8) / 1000;
    pInfo->nSeekTableElements     = static_cast<int>(pInfo->spAPEDescriptor->nSeekTableBytes / 4);

    // check for nonsense in nSeekTableElements field
    if ((pInfo->nAPETotalBytes != APE_FILE_SIZE_UNDEFINED) && (static_cast<int64>(pInfo->nSeekTableElements) > (pInfo->nAPETotalBytes / 4)))
    {
        ASSERT(0);
        return APE_ERROR_INVALID_INPUT_FILE;
    }

    // get the seek tables (really no reason to get the whole thing if there's extra)
    CSmartPtr<uint32> spSeekByteTable32(pInfo->nSeekTableElements);
    if (spSeekByteTable32 == APE_NULL) { return APE_ERROR_UNDEFINED; }

    if ((m_pIO->Read(spSeekByteTable32.GetPtr(), static_cast<int64>(pInfo->nSeekTableElements) * 4, &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != static_cast<int64>(pInfo->nSeekTableElements) * 4))
        return APE_ERROR_IO_READ;

    // convert to int64
    Convert32BitSeekTable(pInfo, spSeekByteTable32, pInfo->nSeekTableElements);

    // get the wave header
    if (!(APEHeader.nFormatFlags & APE_FORMAT_FLAG_CREATE_WAV_HEADER))
    {
        if (pInfo->nWAVHeaderBytes < 0 || pInfo->nWAVHeaderBytes > APE_WAV_HEADER_OR_FOOTER_MAXIMUM_BYTES)
        {
            return APE_ERROR_INVALID_INPUT_FILE;
        }
        if (pInfo->nWAVHeaderBytes > 0)
        {
            pInfo->spWaveHeaderData.AllocateArray(pInfo->nWAVHeaderBytes);
            if (pInfo->spWaveHeaderData == APE_NULL) { return APE_ERROR_UNDEFINED; }
            if ((m_pIO->Read(pInfo->spWaveHeaderData.GetPtr(), static_cast<int64>(pInfo->nWAVHeaderBytes), &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != pInfo->nWAVHeaderBytes))
                return APE_ERROR_IO_READ;
        }
    }

    // check for an invalid blocks per frame
    if (pInfo->nBlocksPerFrame <= 0)
        return APE_ERROR_INVALID_INPUT_FILE;

    if (pInfo->nCompressionLevel >= 5000)
    {
        if (pInfo->nBlocksPerFrame > (10 * APE_ONE_MILLION))
            return APE_ERROR_INVALID_INPUT_FILE;
    }
    else
    {
        if (pInfo->nBlocksPerFrame > APE_ONE_MILLION)
            return APE_ERROR_INVALID_INPUT_FILE;
    }

    // check the final frame size being nonsense
    if (APEHeader.nFinalFrameBlocks > pInfo->nBlocksPerFrame)
        return APE_ERROR_INVALID_INPUT_FILE;

    return APE_ERROR_SUCCESS;
}

int CAPEHeader::AnalyzeOld(APE_FILE_INFO * pInfo)
{
    // variable declares
    int64 nBytesRead = 0;

    // read the MAC header from the file
    APE_HEADER_OLD APEHeader;

    m_pIO->Seek(pInfo->nJunkHeaderBytes, SeekFileBegin);

    if ((m_pIO->Read(&APEHeader, sizeof(APEHeader), &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != sizeof(APEHeader)))
        return APE_ERROR_IO_READ;

    APEHeader.nVersion          = ConvertU16LE(APEHeader.nVersion);
    APEHeader.nCompressionLevel = ConvertU16LE(APEHeader.nCompressionLevel);
    APEHeader.nFormatFlags      = ConvertU16LE(APEHeader.nFormatFlags);

    APEHeader.nChannels         = ConvertU16LE(APEHeader.nChannels);
    APEHeader.nSampleRate       = ConvertU32LE(APEHeader.nSampleRate);

    APEHeader.nHeaderBytes      = ConvertU32LE(APEHeader.nHeaderBytes);
    APEHeader.nTerminatingBytes = ConvertU32LE(APEHeader.nTerminatingBytes);

    APEHeader.nTotalFrames      = ConvertU32LE(APEHeader.nTotalFrames);
    APEHeader.nFinalFrameBlocks = ConvertU32LE(APEHeader.nFinalFrameBlocks);

    // fail on 0 length APE files (catches non-finalized APE files)
    if (APEHeader.nTotalFrames == 0)
        return APE_ERROR_UNDEFINED;

    int nPeakLevel = -1;
    if (APEHeader.nFormatFlags & APE_FORMAT_FLAG_HAS_PEAK_LEVEL)
    {
        m_pIO->Read(&nPeakLevel, 4, &nBytesRead);

        nPeakLevel = ConvertU32LE(nPeakLevel);
    }

    if (APEHeader.nFormatFlags & APE_FORMAT_FLAG_HAS_SEEK_ELEMENTS)
    {
        if ((m_pIO->Read(&pInfo->nSeekTableElements, 4, &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != 4))
            return APE_ERROR_IO_READ;

        pInfo->nSeekTableElements = ConvertU32LE(pInfo->nSeekTableElements);
    }
    else
        pInfo->nSeekTableElements = static_cast<int>(APEHeader.nTotalFrames);

    // fill the APE info structure
    pInfo->nVersionEncoder        = static_cast<int>(APEHeader.nVersion);
    pInfo->nVersionProgram        = 0; // unknown
    pInfo->nCompressionLevel      = static_cast<int>(APEHeader.nCompressionLevel);
    pInfo->nFormatFlags           = static_cast<int>(APEHeader.nFormatFlags);
    pInfo->nTotalFrames           = static_cast<uint32>(APEHeader.nTotalFrames);
    pInfo->nFinalFrameBlocks      = static_cast<uint32>(APEHeader.nFinalFrameBlocks);
    pInfo->nBlocksPerFrame        = static_cast<uint32>(((APEHeader.nVersion >= 3900) || ((APEHeader.nVersion >= 3800) && (APEHeader.nCompressionLevel == APE_COMPRESSION_LEVEL_EXTRA_HIGH))) ? 73728 : 9216);
    if ((APEHeader.nVersion >= 3950)) pInfo->nBlocksPerFrame = 73728 * 4;
    pInfo->nChannels              = static_cast<int>(APEHeader.nChannels);
    pInfo->nSampleRate            = static_cast<int>(APEHeader.nSampleRate);
    pInfo->nBitsPerSample         = (pInfo->nFormatFlags & APE_FORMAT_FLAG_8_BIT) ? 8 : ((pInfo->nFormatFlags & APE_FORMAT_FLAG_24_BIT) ? 24 : 16);
    pInfo->nBytesPerSample        = pInfo->nBitsPerSample / 8;
    pInfo->nBlockAlign            = pInfo->nBytesPerSample * pInfo->nChannels;
    pInfo->nTotalBlocks           = (APEHeader.nTotalFrames == 0) ? 0 : (static_cast<int64>(APEHeader.nTotalFrames -  1) * static_cast<int64>(pInfo->nBlocksPerFrame)) + static_cast<int64>(APEHeader.nFinalFrameBlocks);
    pInfo->nWAVHeaderBytes        = (APEHeader.nFormatFlags & APE_FORMAT_FLAG_CREATE_WAV_HEADER) ? static_cast<int64>(sizeof(WAVE_HEADER)) : APEHeader.nHeaderBytes;
    pInfo->nWAVTerminatingBytes   = static_cast<uint32>(APEHeader.nTerminatingBytes);
    pInfo->nWAVDataBytes          = pInfo->nTotalBlocks * pInfo->nBlockAlign;
    pInfo->nWAVTotalBytes         = pInfo->nWAVDataBytes + pInfo->nWAVHeaderBytes + pInfo->nWAVTerminatingBytes;
    pInfo->nAPETotalBytes         = m_pIO->GetSize();
    pInfo->nLengthMS              = static_cast<int>((static_cast<double>(pInfo->nTotalBlocks) * static_cast<double>(1000)) / static_cast<double>(pInfo->nSampleRate));
    pInfo->nAverageBitrate        = (pInfo->nLengthMS <= 0) ? 0 : static_cast<int>((static_cast<double>(pInfo->nAPETotalBytes) * static_cast<double>(8)) / static_cast<double>(pInfo->nLengthMS));
    pInfo->nDecompressedBitrate   = (pInfo->nBlockAlign * pInfo->nSampleRate * 8) / 1000;

    // check for an invalid blocks per frame
    if (pInfo->nBlocksPerFrame > (10 * APE_ONE_MILLION) || pInfo->nBlocksPerFrame <= 0)
        return APE_ERROR_INVALID_INPUT_FILE;

    // check the final frame size being nonsense
    if (APEHeader.nFinalFrameBlocks > pInfo->nBlocksPerFrame)
        return APE_ERROR_INVALID_INPUT_FILE;

    // check for nonsense in nSeekTableElements field
    if ((pInfo->nAPETotalBytes != APE_FILE_SIZE_UNDEFINED) && (static_cast<int64>(pInfo->nSeekTableElements) > (pInfo->nAPETotalBytes / 4)))
    {
        ASSERT(0);
        return APE_ERROR_INVALID_INPUT_FILE;
    }

    // get the wave header
    if (!(APEHeader.nFormatFlags & APE_FORMAT_FLAG_CREATE_WAV_HEADER) && (APEHeader.nHeaderBytes > 0))
    {
        if (APEHeader.nHeaderBytes > APE_WAV_HEADER_OR_FOOTER_MAXIMUM_BYTES) return APE_ERROR_INVALID_INPUT_FILE;
        if (m_pIO->GetPosition() + APEHeader.nHeaderBytes > m_pIO->GetSize()) { return APE_ERROR_UNDEFINED; }
        pInfo->spWaveHeaderData.AllocateArray(APEHeader.nHeaderBytes);
        if (pInfo->spWaveHeaderData == APE_NULL) { return APE_ERROR_UNDEFINED; }
        if ((m_pIO->Read(pInfo->spWaveHeaderData.GetPtr(), APEHeader.nHeaderBytes, &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != APEHeader.nHeaderBytes))
            return APE_ERROR_IO_READ;
    }

    // get the seek tables (really no reason to get the whole thing if there's extra)
    CSmartPtr<uint32> spSeekByteTable32(pInfo->nSeekTableElements);
    if (spSeekByteTable32 == APE_NULL) { return APE_ERROR_UNDEFINED; }

    if ((m_pIO->Read(spSeekByteTable32.GetPtr(), static_cast<int64>(pInfo->nSeekTableElements) * 4, &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != static_cast<int64>(pInfo->nSeekTableElements) * 4))
        return APE_ERROR_IO_READ;

    // convert to int64
    Convert32BitSeekTable(pInfo, spSeekByteTable32, pInfo->nSeekTableElements);

    // seek bit table (for older files)
#ifdef APE_BACKWARDS_COMPATIBILITY
    if (APEHeader.nVersion <= 3800)
    {
        pInfo->spSeekBitTable.AllocateArray(pInfo->nSeekTableElements);
        if (pInfo->spSeekBitTable == APE_NULL) { return APE_ERROR_UNDEFINED; }

        if ((m_pIO->Read(pInfo->spSeekBitTable.GetPtr(), static_cast<int64>(pInfo->nSeekTableElements), &nBytesRead) != APE_ERROR_SUCCESS) || (nBytesRead != static_cast<unsigned int>(pInfo->nSeekTableElements)))
            return APE_ERROR_IO_READ;
    }
#endif

    return APE_ERROR_SUCCESS;
}

}
