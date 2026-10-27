#include "All.h"
#include "APEDecompress.h"
#include "APEDecompressCore.h"
#include "APEInfo.h"
#include "FloatTransform.h"
#include "GlobalFunctions.h"

namespace APE
{

CAPEDecompress::CAPEDecompress(int * pErrorCode, IAPEInfo * pAPEInfo, int64 nStartBlock, int64 nFinishBlock)
{
    *pErrorCode = APE_ERROR_SUCCESS;

    // initialize
    m_nThreads = 1;
    m_nNextWorker = 0;

    // open / analyze the file
    m_spAPEInfo.Assign(pAPEInfo);

    // store the IO object
    m_spIO.Assign(m_spAPEInfo->GetIO(), false, false);

    // get format information
    m_nBlockAlign = static_cast<int>(m_spAPEInfo->GetInfo(APE_INFO_BLOCK_ALIGN));

    // initialize other stuff
    m_bDecompressorInitialized = false;
    m_nCurrentFrame = 0;
    m_nCurrentBlock = 0;

    // set the "real" start and finish blocks
    m_nStartBlock = (nStartBlock < 0) ? 0 : APE_MIN(nStartBlock, m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS));
    m_nFinishBlock = (nFinishBlock < 0) ? m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS) : APE_MIN(nFinishBlock, m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS));
    m_bIsRanged = (m_nStartBlock != 0) || (m_nFinishBlock != m_spAPEInfo->GetInfo(APE_INFO_TOTAL_BLOCKS));

    // version check (this implementation only works with 3.93 and later files)
    // we do this after setting all the variables or else we get compile warnings
    if (m_spAPEInfo->GetInfo(APE_INFO_FILE_VERSION) < 3930)
    {
        *pErrorCode = APE_ERROR_UNDEFINED;
        return;
    }

    // create a frame buffer
    m_cbFrameBuffer.CreateBuffer(static_cast<uint32>(m_spAPEInfo->GetInfo(APE_INFO_BLOCKS_PER_FRAME) * static_cast<uint32>(m_nBlockAlign)), static_cast<uint32>(m_nBlockAlign * 64));
}

CAPEDecompress::~CAPEDecompress()
{
    // check if we have anything to do
    if (!m_bDecompressorInitialized)
        return;

    // finish threads
    for (int i = 0; i < m_nThreads; i++)
        m_spAPEDecompressCore[i].Delete();
}

int CAPEDecompress::SetNumberOfThreads(int nThreads)
{
    m_nThreads = GetNumberThreads(nThreads);
    return m_nThreads;
}

int CAPEDecompress::InitializeDecompressor()
{
    // check if we have anything to do
    if (m_bDecompressorInitialized)
        return APE_ERROR_SUCCESS;

    // update the initialized flag
    m_bDecompressorInitialized = true;

    // create and start threads
    for (int i = 0; i < m_nThreads; i++)
    {
        int nErrorCode = APE_ERROR_SUCCESS;

        m_spAPEDecompressCore[i].Assign(new CAPEDecompressCore(&nErrorCode, this, m_spAPEInfo));

        if (nErrorCode != APE_ERROR_SUCCESS)
            return nErrorCode;

        m_spAPEDecompressCore[i]->Start();
    }

    // seek to the beginning
    return Seek(0);
}

int CAPEDecompress::GetData(unsigned char * pBuffer, int64 nBlocks, int64 * pBlocksRetrieved, APE_GET_DATA_PROCESSING * pProcessing)
{
    int nResult = APE_ERROR_SUCCESS;
    if (pBlocksRetrieved) *pBlocksRetrieved = 0;

    // make sure we're initialized
    APE_RETURN_ON_ERROR(InitializeDecompressor())

    // cap
    const int64 nBlocksUntilFinish = m_nFinishBlock - m_nCurrentBlock;
    const int64 nBlocksToRetrieve = APE_MIN(nBlocks, nBlocksUntilFinish);

    // get the data
    unsigned char * pBufferGet = pBuffer;
    int64 nBlocksLeft = nBlocksToRetrieve; int nBlocksThisPass = 1;
    while ((nBlocksLeft > 0) && (nBlocksThisPass > 0))
    {
        // check for available data
        int64 nFrameBufferBlocks = static_cast<int64>(m_cbFrameBuffer.MaxGet()) / m_nBlockAlign;

        while (nFrameBufferBlocks == 0 && !nResult)
        {
            m_cbFrameBuffer.Empty();

            // get next worker
            CAPEDecompressCore * pWorker = m_spAPEDecompressCore[m_nNextWorker];

            // get data from decoder
            pWorker->WaitUntilReady();

            nResult = pWorker->GetErrorState();
            if (nResult != APE_ERROR_SUCCESS)
            {
                // output silence
                const uint32 nOutputSilenceBytes = m_cbFrameBuffer.MaxAdd();
                unsigned char cSilence = static_cast<unsigned char>((GetInfo(APE_INFO_BITS_PER_SAMPLE) == 8) ? 127 : 0);

                memset(m_cbFrameBuffer.GetDirectWritePointer(), cSilence, nOutputSilenceBytes);
                m_cbFrameBuffer.UpdateAfterDirectWrite(nOutputSilenceBytes);

                nFrameBufferBlocks = nOutputSilenceBytes / static_cast<uint32>(m_nBlockAlign);
            }
            else if (pWorker->GetFrameBytes() > 0)
            {
                pWorker->GetFrameData(m_cbFrameBuffer.GetDirectWritePointer());
                m_cbFrameBuffer.UpdateAfterDirectWrite(pWorker->GetFrameBytes());

                nFrameBufferBlocks = static_cast<int64>(pWorker->GetFrameBytes()) / m_nBlockAlign;
            }

            // decode next frame
            if (m_nCurrentFrame < m_spAPEInfo->GetInfo(APE_INFO_TOTAL_FRAMES))
            {
                int nScheduleResult = ScheduleFrameDecode(pWorker, m_nCurrentFrame++);
                if (nScheduleResult != APE_ERROR_SUCCESS)
                    nResult = nScheduleResult;
            }
            else
            {
                // reset worker to ready state
                pWorker->SetErrorState(APE_ERROR_SUCCESS);
            }

            m_nNextWorker = (m_nNextWorker + 1) % m_nThreads;
        }

        // analyze how much to remove from the buffer
        nBlocksThisPass = static_cast<int>(APE_MIN(nBlocksLeft, nFrameBufferBlocks));

        // remove as much as possible
        if (nBlocksThisPass > 0)
        {
            m_cbFrameBuffer.Get(pBufferGet, static_cast<uint32>(nBlocksThisPass * m_nBlockAlign));
            pBufferGet = &pBufferGet[nBlocksThisPass * static_cast<int64>(m_nBlockAlign)];
            nBlocksLeft -= nBlocksThisPass;
        }
    }

    // calculate the blocks retrieved
    int64 nBlocksRetrieved = static_cast<int64>(nBlocksToRetrieve - nBlocksLeft);

    // update position
    m_nCurrentBlock += nBlocksRetrieved;
    if (pBlocksRetrieved) *pBlocksRetrieved = nBlocksRetrieved;

    // process data
    const int64 nBlocksDecoded = nBlocksRetrieved;
    if ((pProcessing == APE_NULL) || (pProcessing->bApplyFloatProcessing == true))
    {
        if (GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_FLOATING_POINT)
            CFloatTransform::Process(reinterpret_cast<uint32 *>(pBuffer), nBlocksDecoded * GetInfo(IAPEDecompress::APE_INFO_CHANNELS));
    }

    if ((pProcessing != APE_NULL) && (pProcessing->bApplySigned8BitProcessing == true))
    {
        if (GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_SIGNED_8_BIT)
        {
            const int64 nChannels = GetInfo(IAPEDecompress::APE_INFO_CHANNELS);
            for (int nSample = 0; nSample < nBlocksDecoded * nChannels; nSample++)
            {
                const unsigned char cTemp = pBuffer[nSample];
                const char cTemp2 = static_cast<char>(cTemp + 128);
                pBuffer[nSample] = static_cast<unsigned char>(cTemp2);
            }
        }
    }

    if ((pProcessing != APE_NULL) && (pProcessing->bApplyBigEndianProcessing == true))
    {
        if (GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_BIG_ENDIAN)
        {
            const int64 nBitdepth = GetInfo(IAPEDecompress::APE_INFO_BITS_PER_SAMPLE);
            if (nBitdepth >= 16)
            {
                const int64 nChannels = GetInfo(IAPEDecompress::APE_INFO_CHANNELS);
                SwitchBufferBytes(pBuffer, static_cast<int>(nBitdepth / 8), static_cast<int>(nBlocksDecoded * nChannels));
            }
        }
    }

    return nResult;
}

int CAPEDecompress::Seek(int64 nBlockOffset)
{
    APE_RETURN_ON_ERROR(InitializeDecompressor())

    // cancel frames
    for (int i = 0; i < m_nThreads; i++)
    {
        CAPEDecompressCore * pWorker = m_spAPEDecompressCore[m_nNextWorker];

        pWorker->CancelFrame();

        m_nNextWorker = (m_nNextWorker + 1) % m_nThreads;
    }

    // put the workers in a freshly constructed state so seeks after failures work again
    for (int i = 0; i < m_nThreads; i++)
    {
        CAPEDecompressCore * pWorker = m_spAPEDecompressCore[m_nNextWorker];

        pWorker->WaitUntilReady();
        pWorker->SetErrorState(APE_ERROR_SUCCESS);

        m_nNextWorker = (m_nNextWorker + 1) % m_nThreads;
    }

    // use the offset
    nBlockOffset += m_nStartBlock;

    // cap (to prevent seeking too far)
    if (nBlockOffset >= m_nFinishBlock)
        nBlockOffset = m_nFinishBlock - 1;
    if (nBlockOffset < m_nStartBlock)
        nBlockOffset = m_nStartBlock;

    // seek to the perfect location
    const int64 nBaseFrame = nBlockOffset / GetInfo(APE_INFO_BLOCKS_PER_FRAME);
    const int64 nBlocksToSkip = nBlockOffset % GetInfo(APE_INFO_BLOCKS_PER_FRAME);

    m_nCurrentBlock = nBaseFrame * GetInfo(APE_INFO_BLOCKS_PER_FRAME);
    m_nCurrentFrame = nBaseFrame;
    m_cbFrameBuffer.Empty();

    // skip necessary blocks
    if (nBlocksToSkip > 0)
    {
        const int64 nBytesToSkip = nBlocksToSkip * m_nBlockAlign;

        CSmartPtr<unsigned char> spTempBuffer(nBytesToSkip);
        if (spTempBuffer == APE_NULL)
            return APE_ERROR_INSUFFICIENT_MEMORY;

        int64 nBlocksRetrieved = 0;
        GetData(spTempBuffer, nBlocksToSkip, &nBlocksRetrieved, APE_NULL);
        if (nBlocksRetrieved != nBlocksToSkip)
            return APE_ERROR_UNDEFINED;
    }

    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Read frame data and pass it to worker thread
**************************************************************************************************/
int CAPEDecompress::ScheduleFrameDecode(CAPEDecompressCore * pWorker, int64 nFrameIndex)
{
    const uint32 nSeekRemainder = static_cast<uint32>((GetInfo(APE_INFO_SEEK_BYTE, nFrameIndex) - GetInfo(APE_INFO_SEEK_BYTE, 0)) % 4);
    const uint32 nFrameBytes = static_cast<uint32>(GetInfo(APE_INFO_FRAME_BYTES, nFrameIndex)) + nSeekRemainder + 4;

    unsigned char * pFrameBuffer = pWorker->GetInputBuffer(nFrameBytes);

    int64 nBytesRead = 0;
    int nResult = m_spIO->Seek(GetInfo(APE_INFO_SEEK_BYTE, nFrameIndex) - nSeekRemainder, SeekFileBegin);
    if (nResult != APE_ERROR_SUCCESS)
        return pWorker->SetErrorState(nResult);

    nResult = m_spIO->Read(pFrameBuffer, nFrameBytes, &nBytesRead);
    if (nResult != APE_ERROR_SUCCESS)
        return pWorker->SetErrorState(nResult);

    if (nBytesRead < (static_cast<int64>(nFrameBytes) - 4))
        return pWorker->SetErrorState(APE_ERROR_INPUT_FILE_TOO_SMALL);

    pWorker->DecodeFrame(static_cast<int>(nSeekRemainder), GetInfo(APE_INFO_FRAME_BLOCKS, nFrameIndex));
    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Get information from the decompressor
**************************************************************************************************/
int64 CAPEDecompress::GetInfo(IAPEDecompress::APE_INFO_FIELDS Field, int64 nParam1, int64 nParam2)
{
    int64 nResult = 0;
    bool bHandled = false;

    switch (Field)
    {
    case APE_DECOMPRESS_CURRENT_BLOCK:
    {
        nResult = static_cast<int64>(m_nCurrentBlock - m_nStartBlock);
        bHandled = true;
        break;
    }
    case APE_DECOMPRESS_CURRENT_MS:
    {
        const int64 nSampleRate = m_spAPEInfo->GetInfo(APE_INFO_SAMPLE_RATE, 0, 0);
        if (nSampleRate > 0)
        {
            nResult = static_cast<int64>((static_cast<double>(m_nCurrentBlock) * static_cast<double>(1000)) / static_cast<double>(nSampleRate));
            bHandled = true;
        }
        break;
    }
    case APE_DECOMPRESS_TOTAL_BLOCKS:
    {
        nResult = m_nFinishBlock - m_nStartBlock;
        bHandled = true;
        break;
    }
    case APE_DECOMPRESS_LENGTH_MS:
    {
        const int64 nSampleRate = static_cast<int64>(m_spAPEInfo->GetInfo(APE_INFO_SAMPLE_RATE, 0, 0));
        if (nSampleRate > 0)
        {
            nResult = static_cast<int64>((static_cast<double>(m_nFinishBlock - m_nStartBlock) * static_cast<double>(1000)) / static_cast<double>(nSampleRate));
            bHandled = true;
        }
        break;
    }
    case APE_DECOMPRESS_CURRENT_BITRATE:
    {
        nResult = GetInfo(APE_INFO_FRAME_BITRATE, m_nCurrentFrame);
        bHandled = true;
        break;
    }
    case APE_DECOMPRESS_CURRENT_FRAME:
    {
        nResult = m_nCurrentFrame;
        bHandled = true;
        break;
    }
    case APE_DECOMPRESS_AVERAGE_BITRATE:
    {
        if (m_bIsRanged)
        {
            // figure the frame range
            const int64 nBlocksPerFrame = GetInfo(APE_INFO_BLOCKS_PER_FRAME);
            const int64 nStartFrame = static_cast<int64>(m_nStartBlock / nBlocksPerFrame);
            const int64 nFinishFrame = static_cast<int64>(m_nFinishBlock + nBlocksPerFrame - 1) / nBlocksPerFrame;

            // get the number of bytes in the first and last frame
            int64 nTotalBytes = (GetInfo(APE_INFO_FRAME_BYTES, nStartFrame) * (m_nStartBlock % nBlocksPerFrame)) / nBlocksPerFrame;
            if (nFinishFrame != nStartFrame)
                nTotalBytes += (GetInfo(APE_INFO_FRAME_BYTES, nFinishFrame) * (m_nFinishBlock % nBlocksPerFrame)) / nBlocksPerFrame;

            // get the number of bytes in between
            const int64 nTotalFrames = GetInfo(APE_INFO_TOTAL_FRAMES);
            for (int64 nFrame = nStartFrame + 1; (nFrame < nFinishFrame) && (nFrame < nTotalFrames); nFrame++)
                nTotalBytes += GetInfo(APE_INFO_FRAME_BYTES, nFrame);

            // figure the bitrate
            const int64 nTotalMS = static_cast<int64>((static_cast<double>(m_nFinishBlock - m_nStartBlock) * static_cast<double>(1000)) / static_cast<double>(GetInfo(APE_INFO_SAMPLE_RATE)));
            if (nTotalMS != 0)
                nResult = static_cast<int64>((nTotalBytes * 8) / nTotalMS);
        }
        else
        {
            nResult = GetInfo(APE_INFO_AVERAGE_BITRATE);
        }
        bHandled = true;
        break;
    }
    case APE_INFO_WAV_HEADER_BYTES:
    {
        if (m_bIsRanged)
        {
            nResult = sizeof(WAVE_HEADER);
            bHandled = true;
        }
        break;
    }
    case APE_INFO_WAV_HEADER_DATA:
    {
        if (m_bIsRanged)
        {
            char * pBuffer = reinterpret_cast<char *>(nParam1);
            const int64 nMaxBytes = nParam2;

            if (static_cast<APE::int64>(sizeof(WAVE_HEADER)) > nMaxBytes)
            {
                nResult = -1;
            }
            else
            {
                WAVEFORMATEX wfeFormat;
                GetInfo(APE_INFO_WAVEFORMATEX, APE_POINTER_TO_INT64(&wfeFormat), 0);
                WAVE_HEADER WAVHeader; FillWaveHeader(&WAVHeader,
                    (m_nFinishBlock - m_nStartBlock) * GetInfo(APE_INFO_BLOCK_ALIGN),
                    &wfeFormat, 0);
                memcpy(pBuffer, &WAVHeader, sizeof(WAVE_HEADER));
                nResult = 0;
            }
            bHandled = true;
        }

        break;
    }
    case APE_INFO_WAV_TERMINATING_BYTES:
    {
        if (m_bIsRanged)
        {
            nResult = 0;
            bHandled = true;
        }
        break;
    }
    case APE_INFO_WAV_TERMINATING_DATA:
    {
        if (m_bIsRanged)
        {
            nResult = 0;
            bHandled = true;
        }
        break;
    }
    case APE_INFO_APE_TOTAL_BYTES:
    case APE_INFO_APL:
    case APE_INFO_AVERAGE_BITRATE:
    case APE_INFO_BITS_PER_SAMPLE:
    case APE_INFO_BLOCKS_PER_FRAME:
    case APE_INFO_BLOCK_ALIGN:
    case APE_INFO_BYTES_PER_SAMPLE:
    case APE_INFO_CHANNELS:
    case APE_INFO_COMPRESSION_LEVEL:
    case APE_INFO_DECOMPRESSED_BITRATE:
    case APE_INFO_FILE_VERSION:
    case APE_INFO_FINAL_FRAME_BLOCKS:
    case APE_INFO_FORMAT_FLAGS:
    case APE_INFO_FRAME_BITRATE:
    case APE_INFO_FRAME_BLOCKS:
    case APE_INFO_FRAME_BYTES:
    case APE_INFO_IO_SOURCE:
    case APE_INFO_LENGTH_MS:
    case APE_INFO_MD5:
    case APE_INFO_MD5_MATCHES:
    case APE_INFO_PEAK_LEVEL:
    case APE_INFO_SAMPLE_RATE:
    case APE_INFO_SEEK_BIT:
    case APE_INFO_SEEK_BYTE:
    case APE_INFO_TAG:
    case APE_INFO_TOTAL_BLOCKS:
    case APE_INFO_TOTAL_FRAMES:
    case APE_INFO_WAVEFORMATEX:
    case APE_INFO_WAV_DATA_BYTES:
    case APE_INFO_WAV_TOTAL_BYTES:
    case APE_INFO_FILE_INFO:
    case APE_INFO_PROGRAM_VERSION:
    {
        // all other conditions to prevent compiler warnings (4061, 4062, and Clang)
        break;
    }
    }

    if (!bHandled)
        nResult = m_spAPEInfo->GetInfo(Field, nParam1, nParam2);

    return nResult;
}

}
