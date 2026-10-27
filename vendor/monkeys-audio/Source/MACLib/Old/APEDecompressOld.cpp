#include "All.h"
#ifdef APE_BACKWARDS_COMPATIBILITY

#include "APEDecompressOld.h"
#include "APEInfo.h"

namespace APE
{

CAPEDecompressOld::CAPEDecompressOld(int * pErrorCode, IAPEInfo * pAPEInfo, int nStartBlock, int nFinishBlock)
{
    *pErrorCode = APE_ERROR_SUCCESS;

    // open / analyze the file
    m_spAPEInfo.Assign(pAPEInfo);

    // create the buffer
    m_nBlockAlign = m_spAPEInfo->GetInfo(APE_INFO_BLOCK_ALIGN);

    // initialize other stuff
    m_nBufferTail = 0;
    m_bDecompressorInitialized = false;
    m_nCurrentFrame = 0;
    m_nCurrentBlock = 0;

    // set the "real" start and finish blocks
    m_nStartBlock = (nStartBlock < 0) ? 0 : APE_MIN(nStartBlock, static_cast<int>(m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS)));
    m_nFinishBlock = (nFinishBlock < 0) ? static_cast<int>(m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS)) : APE_MIN(nFinishBlock, static_cast<int>(m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS)));
    m_bIsRanged = (m_nStartBlock != 0) || (m_nFinishBlock != static_cast<int>(m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS)));

    // version check (this implementation only works with 3.92 and earlier files)
    // do this after initializing variables or else we get a warning
    if (m_spAPEInfo->GetInfo(APE_INFO_FILE_VERSION) > 3920)
    {
        *pErrorCode = APE_ERROR_UNDEFINED;
        return;
    }

    // check block alignment
    if ((m_nBlockAlign <= 0) || (m_nBlockAlign > 32))
    {
        *pErrorCode = APE_ERROR_INVALID_INPUT_FILE;
        return;
    }
}

CAPEDecompressOld::~CAPEDecompressOld()
{
}

int CAPEDecompressOld::SetNumberOfThreads(int)
{
    return 1;
}

int CAPEDecompressOld::InitializeDecompressor()
{
    // check if we have anything to do
    if (m_bDecompressorInitialized)
        return APE_ERROR_SUCCESS;

    // initialize the decoder
    APE_RETURN_ON_ERROR(m_UnMAC.Initialize(this))

    const int64 nMaximumDecompressedFrameBytes = m_nBlockAlign * static_cast<intn>(GetInfo(APE_INFO_BLOCKS_PER_FRAME));
    const int64 nTotalBufferBytes = APE_MAX<int64>(65536, (nMaximumDecompressedFrameBytes + 16) * 2);
    m_spBuffer.AllocateArray(nTotalBufferBytes);
    if (m_spBuffer == APE_NULL)
        return APE_ERROR_INSUFFICIENT_MEMORY;

    // update the initialized flag
    m_bDecompressorInitialized = true;

    // seek to the beginning
    return Seek(0);
}

int CAPEDecompressOld::GetData(unsigned char * pBuffer, int64 nBlocks, int64 * pBlocksRetrieved, APE_GET_DATA_PROCESSING *)
{
    if (pBlocksRetrieved) *pBlocksRetrieved = 0;

    APE_RETURN_ON_ERROR(InitializeDecompressor())

    // cap
    const int64 nBlocksUntilFinish = m_nFinishBlock - m_nCurrentBlock;
    nBlocks = APE_MIN(nBlocks, nBlocksUntilFinish);

    int64 nBlocksRetrieved = 0;

    // fulfill as much of the request as possible
    int64 nTotalBytesNeeded = nBlocks * m_nBlockAlign;
    int64 nBytesLeft = nTotalBytesNeeded;
    int64 nBlocksDecoded = 1;

    while (nBytesLeft > 0 && nBlocksDecoded > 0)
    {
        // empty the buffer
        const int64 nBytesAvailable = m_nBufferTail;
        const int64 nIntialBytes = APE_MIN(nBytesLeft, nBytesAvailable);
        if (nIntialBytes > 0)
        {
            memcpy(&pBuffer[nTotalBytesNeeded - nBytesLeft], &m_spBuffer[0], static_cast<size_t>(nIntialBytes));

            if ((m_nBufferTail - nIntialBytes) > 0)
                memmove(&m_spBuffer[0], &m_spBuffer[nIntialBytes], static_cast<size_t>(m_nBufferTail - nIntialBytes));

            nBytesLeft -= nIntialBytes;
            m_nBufferTail -= nIntialBytes;

        }

        // decode more
        if (nBytesLeft > 0)
        {
            int nErrorCode = APE_ERROR_UNDEFINED;
            nBlocksDecoded = m_UnMAC.DecompressFrame(&m_spBuffer[m_nBufferTail], static_cast<int32>(m_nCurrentFrame++), &nErrorCode);
            if (nBlocksDecoded < 0)
                return nErrorCode;
            m_nBufferTail += (nBlocksDecoded * m_nBlockAlign);
        }
    }

    nBlocksRetrieved = (nTotalBytesNeeded - nBytesLeft) / m_nBlockAlign;

    // update the position
    m_nCurrentBlock += nBlocksRetrieved;

    if (pBlocksRetrieved) *pBlocksRetrieved = nBlocksRetrieved;

    return APE_ERROR_SUCCESS;
}

int CAPEDecompressOld::Seek(int64 nBlockOffset)
{
    if (m_bDecompressorInitialized)
    {
        // re-initialize the decoder so we reset everything on seek after an error
        APE_RETURN_ON_ERROR(m_UnMAC.Initialize(this))
    }
    else
    {
        // initial initialize
        APE_RETURN_ON_ERROR(InitializeDecompressor())
    }

    // use the offset
    nBlockOffset += m_nStartBlock;

    // cap (to prevent seeking too far)
    if (nBlockOffset >= m_nFinishBlock)
        nBlockOffset = m_nFinishBlock - 1;
    if (nBlockOffset < m_nStartBlock)
        nBlockOffset = m_nStartBlock;

    // flush the buffer
    m_nBufferTail = 0;

    // seek to the perfect location
    const int64 nBaseFrame = nBlockOffset / static_cast<intn>(GetInfo(APE_INFO_BLOCKS_PER_FRAME));
    const int64 nBlocksToSkip = nBlockOffset % static_cast<intn>(GetInfo(APE_INFO_BLOCKS_PER_FRAME));
    const int64 nBytesToSkip = nBlocksToSkip * m_nBlockAlign;

    // skip necessary blocks
    const int64 nMaximumDecompressedFrameBytes = m_nBlockAlign * static_cast<int>(GetInfo(APE_INFO_BLOCKS_PER_FRAME));
    CSmartPtr<unsigned char> spTempBuffer(nMaximumDecompressedFrameBytes + 16);
    APE_CLEAR_ARRAY(spTempBuffer.GetPtr(), nMaximumDecompressedFrameBytes + 16);

    m_nCurrentFrame = nBaseFrame;

    int nErrorCode = APE_ERROR_UNDEFINED;
    const intn nBlocksDecoded = m_UnMAC.DecompressFrame(spTempBuffer.GetPtr(), static_cast<int32>(m_nCurrentFrame++), &nErrorCode);

    if (nBlocksDecoded < 0)
        return nErrorCode;

    const int64 nBytesToKeep = (nBlocksDecoded * m_nBlockAlign) - nBytesToSkip;
    memcpy(&m_spBuffer[m_nBufferTail], &spTempBuffer[nBytesToSkip], static_cast<size_t>(nBytesToKeep));
    m_nBufferTail += nBytesToKeep;

    m_nCurrentBlock = nBlockOffset;

    return APE_ERROR_SUCCESS;
}

int64 CAPEDecompressOld::GetInfo(APE_INFO_FIELDS Field, int64 nParam1, int64 nParam2)
{
    int64 nRetVal = 0;
    bool bHandled = true;

    if (Field == APE_DECOMPRESS_CURRENT_BLOCK)
    {
        nRetVal = m_nCurrentBlock - m_nStartBlock;
    }
    else if (Field == APE_DECOMPRESS_CURRENT_MS)
    {
        const int64 nSampleRate = m_spAPEInfo->GetInfo(APE_INFO_SAMPLE_RATE, 0, 0);
        if (nSampleRate > 0)
            nRetVal = static_cast<int64>((static_cast<double>(m_nCurrentBlock) * static_cast<double>(1000)) / static_cast<double>(nSampleRate));
    }
    else if (Field == APE_DECOMPRESS_TOTAL_BLOCKS)
    {
        nRetVal = m_nFinishBlock - m_nStartBlock;
    }
    else if (Field == APE_DECOMPRESS_LENGTH_MS)
    {
        const int64 nSampleRate = m_spAPEInfo->GetInfo(APE_INFO_SAMPLE_RATE, 0, 0);
        if (nSampleRate > 0)
            nRetVal = static_cast<int64>((static_cast<double>(m_nFinishBlock - m_nStartBlock) * static_cast<double>(1000)) / static_cast<double>(nSampleRate));
    }
    else if (Field == APE_DECOMPRESS_CURRENT_BITRATE)
    {
        nRetVal = GetInfo(APE_INFO_FRAME_BITRATE, static_cast<intn>(m_nCurrentFrame));
    }
    else if (Field == APE_DECOMPRESS_AVERAGE_BITRATE)
    {
        if (m_bIsRanged)
        {
            // figure the frame range
            const int64 nBlocksPerFrame = GetInfo(APE_INFO_BLOCKS_PER_FRAME);
            const int64 nStartFrame = m_nStartBlock / nBlocksPerFrame;
            const int64 nFinishFrame = (m_nFinishBlock + nBlocksPerFrame - 1) / nBlocksPerFrame;

            // get the number of bytes in the first and last frame
            int64 nTotalBytes = (GetInfo(APE_INFO_FRAME_BYTES, static_cast<intn>(nStartFrame)) * (m_nStartBlock % nBlocksPerFrame)) / nBlocksPerFrame;
            if (nFinishFrame != nStartFrame)
                nTotalBytes += (GetInfo(APE_INFO_FRAME_BYTES, static_cast<intn>(nFinishFrame)) * (m_nFinishBlock % nBlocksPerFrame)) / nBlocksPerFrame;

            // get the number of bytes in between
            const int64 nTotalFrames = GetInfo(APE_INFO_TOTAL_FRAMES);
            for (int64 nFrame = nStartFrame + 1; (nFrame < nFinishFrame) && (nFrame < nTotalFrames); nFrame++)
                nTotalBytes += GetInfo(APE_INFO_FRAME_BYTES, nFrame);

            // figure the bitrate
            const int64 nTotalMS = static_cast<int64>((static_cast<double>(m_nFinishBlock - m_nStartBlock) * static_cast<double>(1000)) / static_cast<double>(GetInfo(APE_INFO_SAMPLE_RATE)));
            if (nTotalMS != 0)
                nRetVal = (nTotalBytes * 8) / nTotalMS;
        }
        else
        {
            nRetVal = GetInfo(APE_INFO_AVERAGE_BITRATE);
        }
    }
    else
    {
        bHandled = false;
    }

    if (!bHandled && m_bIsRanged)
    {
        bHandled = true;

        if (Field == APE_INFO_WAV_HEADER_BYTES)
        {
            nRetVal = sizeof(WAVE_HEADER);
        }
        else if (Field == APE_INFO_WAV_HEADER_DATA)
        {
            char * pBuffer = reinterpret_cast<char *>(nParam1);
            const int nMaxBytes = static_cast<int>(nParam2);

            if (sizeof(WAVE_HEADER) > static_cast<size_t>(nMaxBytes))
            {
                nRetVal = -1;
            }
            else
            {
                WAVEFORMATEX wfeFormat;
                GetInfo(APE_INFO_WAVEFORMATEX, APE_POINTER_TO_INT64(&wfeFormat), 0);

                WAVE_HEADER WAVHeader;
                FillWaveHeader(&WAVHeader,
                    (m_nFinishBlock - m_nStartBlock) * static_cast<intn>(GetInfo(APE_INFO_BLOCK_ALIGN)),
                    &wfeFormat, 0);
                memcpy(pBuffer, &WAVHeader, sizeof(WAVE_HEADER));
                nRetVal = 0;
            }
        }
        else if (Field == APE_INFO_WAV_TERMINATING_BYTES)
        {
            nRetVal = 0;
        }
        else if (Field == APE_INFO_WAV_TERMINATING_DATA)
        {
            nRetVal = 0;
        }
        else
        {
            bHandled = false;
        }
    }

    if (!bHandled)
        nRetVal = m_spAPEInfo->GetInfo(Field, nParam1, nParam2);

    return nRetVal;
}

}

#endif // #ifdef APE_BACKWARDS_COMPATIBILITY
