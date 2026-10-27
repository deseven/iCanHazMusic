#include "All.h"
#include "APEDecompress.h"
#include "APEDecompressCore.h"
#include "APEInfo.h"
#include "NewPredictor.h"
#include "Old/NewPredictorOld.h"
#include "MemoryIO.h"
#include "Interim.h"

namespace APE
{

CAPEDecompressCore::CAPEDecompressCore(int * pErrorCode, CAPEDecompress * pDecompress, IAPEInfo * pAPEInfo)
: m_semProcess(1), m_semReady(1)
{
    m_semProcess.Wait();

    *pErrorCode = APE_ERROR_SUCCESS;

    // open / analyze the file
    m_pAPEInfo = pAPEInfo;
    m_pDecompress = pDecompress;

    // get format information
    m_pAPEInfo->GetInfo(IAPEDecompress::APE_INFO_WAVEFORMATEX, APE_POINTER_TO_INT64(&m_wfeInput));
    m_nBlockAlign = static_cast<int>(m_pAPEInfo->GetInfo(IAPEDecompress::APE_INFO_BLOCK_ALIGN));

    // initialize other stuff
    m_nInputBytes = 0;
    m_nSkipBytes = 0;
    m_bDecompressorInitialized = false;
    m_nFrameBlocks = 0;
    m_bErrorDecodingCurrentFrame = false;
    m_bInterimMode = false;
    m_nLastX = 0;
    m_nSpecialCodes = 0;
    m_nCRC = 0;
    m_nStoredCRC = 0;
    m_nErrorState = APE_ERROR_SUCCESS;
    m_bCancelFrame = false;
    m_bExit = false;
    APE_CLEAR(m_aryBitArrayStates);

    // channel data
    m_sparyChannelData.AllocateArray(APE_MAXIMUM_CHANNELS);

    // predictors
    APE_CLEAR(m_aryPredictor);

    // version check (this implementation only works with 3.93 and later files)
    // we do this after setting all the variables or else we get compile warnings
    if (m_pAPEInfo->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) < 3930)
    {
        *pErrorCode = APE_ERROR_UNDEFINED;
        return;
    }
}

CAPEDecompressCore::~CAPEDecompressCore()
{
    // stop any threading
    Exit();
    Wait();

    // delete the predictors
    for (int z = 0; z < APE_MAXIMUM_CHANNELS; z++)
    {
        if (m_aryPredictor[z] != APE_NULL)
            delete m_aryPredictor[z];
    }
}

void CAPEDecompressCore::Run()
{
    while (!m_bExit)
    {
        m_semProcess.Wait();

        if (m_bExit) break;

        int nResult = DecodeFrame();
        if (nResult != APE_ERROR_SUCCESS)
            SetErrorState(nResult);
        else
            m_semReady.Post();
    }
}

void CAPEDecompressCore::DecodeFrame(int nSkipBytes, int64 nFrameBlocks)
{
    m_spUnBitArray->FillAndResetBitArray(0, static_cast<int64>(nSkipBytes) * 8);
    m_nSkipBytes = nSkipBytes;
    m_nFrameBlocks = nFrameBlocks;
    m_nErrorState = APE_ERROR_SUCCESS;
    m_bCancelFrame = false;

    m_semProcess.Post();
}

void CAPEDecompressCore::CancelFrame()
{
    m_bCancelFrame = true;
}

unsigned char * CAPEDecompressCore::GetInputBuffer(uint32 nInputBytes)
{
    if (m_nInputBytes < nInputBytes)
    {
        m_spInputData.AllocateArray(nInputBytes);
        m_spIO.Assign(new CMemoryIO(m_spInputData, static_cast<int>(nInputBytes)));
        m_spUnBitArray.Assign(CreateUnBitArray(m_pDecompress, m_spIO, static_cast<int>(m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION))));
        m_nInputBytes = nInputBytes;
    }

    return m_spInputData;
}

void CAPEDecompressCore::GetFrameData(unsigned char * pBuffer)
{
    m_cbFrameBuffer.Get(pBuffer, GetFrameBytes());
}

uint32 CAPEDecompressCore::GetFrameBytes() const
{
    if (m_bCancelFrame || m_nErrorState != APE_ERROR_SUCCESS)
        return 0;

    return static_cast<uint32>(m_nFrameBlocks) * static_cast<uint32>(m_nBlockAlign);
}

int CAPEDecompressCore::SetErrorState(int nError)
{
    m_nErrorState = nError;
    m_cbFrameBuffer.Empty();

    m_semReady.Post();

    return m_nErrorState;
}

int CAPEDecompressCore::GetErrorState() const
{
    return m_nErrorState;
}

int CAPEDecompressCore::InitializeDecompressor()
{
    // check if we have anything to do
    if (m_bDecompressorInitialized)
        return APE_ERROR_SUCCESS;

    // check the block align
    if ((m_nBlockAlign <= 0) || (m_nBlockAlign > 256))
        return APE_ERROR_INVALID_INPUT_FILE;

    // create a frame buffer
    m_cbFrameBuffer.CreateBuffer(static_cast<uint32>(m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCKS_PER_FRAME)) * static_cast<uint32>(m_nBlockAlign), static_cast<uint32>(m_nBlockAlign * 64));

    // create the predictors
    const int nChannels = APE_CAP(static_cast<int>(m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_CHANNELS)), 1, 32);
    const int nCompressionLevel = static_cast<int>(m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_COMPRESSION_LEVEL));
    const int nBitsPerSample = static_cast<int>(m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_BITS_PER_SAMPLE));

    // get version
    m_Version = APE_VERSION(static_cast<int>(m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION)), static_cast<int>(m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_PROGRAM_VERSION)), 0);

    // loop channels
    int nResult = APE_ERROR_UNDEFINED;
    for (int nChannel = 0; nChannel < nChannels; nChannel++)
    {
        if (m_Version.m_nFileVersion >= 3950)
        {
            if (nBitsPerSample < 32)
                m_aryPredictor[nChannel] = new CPredictorDecompress3950toCurrent<int, short>(nCompressionLevel, m_Version, nBitsPerSample);
            else
                m_aryPredictor[nChannel] = new CPredictorDecompress3950toCurrent<int64, int>(nCompressionLevel, m_Version, nBitsPerSample);

            nResult = APE_ERROR_SUCCESS;
        }
#ifdef APE_BACKWARDS_COMPATIBILITY
        else
        {
            m_aryPredictor[nChannel] = new CPredictorDecompress3930to3950(nCompressionLevel, m_Version);

            nResult = APE_ERROR_SUCCESS;
        }
#endif
    }

    // update the initialized flag
    if (nResult == APE_ERROR_SUCCESS)
        m_bDecompressorInitialized = true;

    return nResult;
}

/**************************************************************************************************
Decodes blocks of data
**************************************************************************************************/
int CAPEDecompressCore::DecodeFrame()
{
    // initialize
    int nResult = InitializeDecompressor();

    // empty the buffer
    m_cbFrameBuffer.Empty();

    // determine the maximum blocks we can decode
    // note that we won't do end capping because we can't use data
    // until EndFrame(...) successfully handles the frame
    // that means we may decode a little extra in end capping cases
    // but this allows robust error handling of bad frames
    int64 nBlocksLeft = m_nFrameBlocks;
    if (nBlocksLeft <= 0)
        nResult = APE_ERROR_DECOMPRESSING_FRAME;

    // loop and decode data (if there's a failure above we won't even enter the loop)
    while ((nBlocksLeft > 0) && (nResult == APE_ERROR_SUCCESS))
    {
        // analyze
        const int64 nBlocksThisPass = m_nFrameBlocks;

        // start the frame
        StartFrame();

        // decode data
        DecodeBlocksToFrameBuffer(nBlocksThisPass);

        // end the frame
        EndFrame();

        // handle errors (either mid-frame or from a CRC at the end of the frame)
        if (m_bErrorDecodingCurrentFrame)
        {
            // remove any decoded data for this frame from the buffer
            m_cbFrameBuffer.Empty();

            // enter interim mode if we're a 24-bit file and try the frame again
            // this is because for a while (from the addition of 32-bit to version 8.50) we would encode the file using int64 values instead of int32 values for a couple things
            if ((m_bInterimMode == false) && (m_pDecompress->GetInfo(IAPEDecompress::APE_INFO_BITS_PER_SAMPLE) == 24))
            {
                m_bInterimMode = true;
                for (int z = 0; z < APE_MAXIMUM_CHANNELS; z++)
                {
                    if (m_aryPredictor[z] != APE_NULL)
                    {
                        delete m_aryPredictor[z];
                        m_Version.m_nFlags |= APE_VERSION_FLAG_INTERIM;
                        m_aryPredictor[z] = new APE::CPredictorDecompressInterim(static_cast<int>(m_pAPEInfo->GetInfo(IAPEInfo::APE_INFO_COMPRESSION_LEVEL)), m_Version, static_cast<int>(m_pAPEInfo->GetInfo(IAPEInfo::APE_INFO_BITS_PER_SAMPLE)));
                    }
                }
                m_spUnBitArray->FillAndResetBitArray(0, static_cast<int64>(m_nSkipBytes) * 8);
                continue;
            }
            else
            {
                // save the return value
                nResult = APE_ERROR_INVALID_CHECKSUM;
            }
        }

        nBlocksLeft -= nBlocksThisPass;
    }

    return nResult;
}

void CAPEDecompressCore::DecodeBlocksToFrameBuffer(int64 nBlocks)
{
    // decode the samples
    int nBlocksProcessed = 0;
    const int nFrameBufferBytes = static_cast<int>(m_cbFrameBuffer.MaxGet());

    try
    {
        if (m_wfeInput.nChannels > 2)
        {
            for (nBlocksProcessed = 0; nBlocksProcessed < nBlocks; nBlocksProcessed++)
            {
                for (int nChannel = 0; nChannel < m_wfeInput.nChannels; nChannel++)
                {
                    const int64 nValue = m_spUnBitArray->DecodeValueRange(m_aryBitArrayStates[nChannel]);
                    const int nValue2 = m_aryPredictor[nChannel]->DecompressValue(nValue, 0);
                    m_sparyChannelData[nChannel] = nValue2;
                }
                m_Prepare.Unprepare(m_sparyChannelData, &m_wfeInput, m_cbFrameBuffer.GetDirectWritePointer());
                m_cbFrameBuffer.UpdateAfterDirectWrite(static_cast<uint32>(m_nBlockAlign));
            }
        }
        else if (m_wfeInput.nChannels == 2)
        {
            if ((m_nSpecialCodes & APE_SPECIAL_FRAME_LEFT_SILENCE) &&
                (m_nSpecialCodes & APE_SPECIAL_FRAME_RIGHT_SILENCE))
            {
                for (nBlocksProcessed = 0; nBlocksProcessed < nBlocks; nBlocksProcessed++)
                {
                    int aryValues[2] = { 0, 0 };
                    m_Prepare.Unprepare(aryValues, &m_wfeInput, m_cbFrameBuffer.GetDirectWritePointer());
                    m_cbFrameBuffer.UpdateAfterDirectWrite(static_cast<uint32>(m_nBlockAlign));
                }
            }
            else if (m_nSpecialCodes & APE_SPECIAL_FRAME_PSEUDO_STEREO)
            {
                for (nBlocksProcessed = 0; nBlocksProcessed < nBlocks; nBlocksProcessed++)
                {
                    int aryValues[2] = { m_aryPredictor[0]->DecompressValue(m_spUnBitArray->DecodeValueRange(m_aryBitArrayStates[0])), 0 };

                    m_Prepare.Unprepare(aryValues, &m_wfeInput, m_cbFrameBuffer.GetDirectWritePointer());
                    m_cbFrameBuffer.UpdateAfterDirectWrite(static_cast<uint32>(m_nBlockAlign));
                }
            }
            else
            {
                if (m_pAPEInfo->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) >= 3950)
                {
                    for (nBlocksProcessed = 0; nBlocksProcessed < nBlocks; nBlocksProcessed++)
                    {
                        const int64 nY = m_spUnBitArray->DecodeValueRange(m_aryBitArrayStates[1]);
                        const int64 nX = m_spUnBitArray->DecodeValueRange(m_aryBitArrayStates[0]);
                        int Y = m_aryPredictor[1]->DecompressValue(nY, m_nLastX);
                        int X = m_aryPredictor[0]->DecompressValue(nX, Y);
                        m_nLastX = X;

                        int aryValues[2] = { X, Y };
                        unsigned char * pOutput = m_cbFrameBuffer.GetDirectWritePointer();
                        m_Prepare.Unprepare(aryValues, &m_wfeInput, pOutput);
                        m_cbFrameBuffer.UpdateAfterDirectWrite(static_cast<uint32>(m_nBlockAlign));
                    }
                }
                else
                {
                    for (nBlocksProcessed = 0; nBlocksProcessed < nBlocks; nBlocksProcessed++)
                    {
                        int X = m_aryPredictor[0]->DecompressValue(m_spUnBitArray->DecodeValueRange(m_aryBitArrayStates[0]));
                        int Y = m_aryPredictor[1]->DecompressValue(m_spUnBitArray->DecodeValueRange(m_aryBitArrayStates[1]));

                        int aryValues[2] = { X, Y };
                        m_Prepare.Unprepare(aryValues, &m_wfeInput, m_cbFrameBuffer.GetDirectWritePointer());
                        m_cbFrameBuffer.UpdateAfterDirectWrite(static_cast<uint32>(m_nBlockAlign));
                    }
                }
            }
        }
        else if (m_wfeInput.nChannels == 1)
        {
            if (m_nSpecialCodes & APE_SPECIAL_FRAME_MONO_SILENCE)
            {
                for (nBlocksProcessed = 0; nBlocksProcessed < nBlocks; nBlocksProcessed++)
                {
                    int aryValues[2] = { 0, 0 };
                    m_Prepare.Unprepare(aryValues, &m_wfeInput, m_cbFrameBuffer.GetDirectWritePointer());
                    m_cbFrameBuffer.UpdateAfterDirectWrite(static_cast<uint32>(m_nBlockAlign));
                }
            }
            else
            {
                for (nBlocksProcessed = 0; nBlocksProcessed < nBlocks; nBlocksProcessed++)
                {
                    int aryValues[2] = { m_aryPredictor[0]->DecompressValue(m_spUnBitArray->DecodeValueRange(m_aryBitArrayStates[0])), 0 };
                    m_Prepare.Unprepare(aryValues, &m_wfeInput, m_cbFrameBuffer.GetDirectWritePointer());
                    m_cbFrameBuffer.UpdateAfterDirectWrite(static_cast<uint32>(m_nBlockAlign));
                }
            }
        }
    }
    catch(...)
    {
        m_bErrorDecodingCurrentFrame = true;
    }

    // get actual blocks that have been decoded and added to the frame buffer
    int nActualBlocks = (static_cast<int>(m_cbFrameBuffer.MaxGet()) - nFrameBufferBytes) / m_nBlockAlign;
    nActualBlocks = APE_MAX(nActualBlocks, 0);
    if (nBlocks != nActualBlocks)
        m_bErrorDecodingCurrentFrame = true;

    // update CRC
    m_nCRC = m_cbFrameBuffer.UpdateCRC(m_nCRC, static_cast<uint32>(m_wfeInput.wBitsPerSample / 8), static_cast<uint32>(nActualBlocks) * m_wfeInput.nChannels);
}

void CAPEDecompressCore::StartFrame()
{
    m_nCRC = 0xFFFFFFFF;

    // get the frame header
    m_nStoredCRC = static_cast<unsigned int>(m_spUnBitArray->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_UNSIGNED_INT));
    m_bErrorDecodingCurrentFrame = false;

    // get any 'special' codes if the file uses them (for silence, false stereo, etc.)
    m_nSpecialCodes = 0;
    if (APE_GET_USES_SPECIAL_FRAMES(m_pAPEInfo))
    {
        if (m_nStoredCRC & 0x80000000)
        {
            m_nSpecialCodes = static_cast<int>(m_spUnBitArray->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_UNSIGNED_INT));
        }
        m_nStoredCRC &= 0x7FFFFFFF;
    }

    for (int z = 0; z < APE_MAXIMUM_CHANNELS; z++)
    {
        if (m_aryPredictor[z] != APE_NULL)
            m_aryPredictor[z]->Flush();
    }

    for (int z = 0; z < APE_MAXIMUM_CHANNELS; z++)
    {
        m_spUnBitArray->FlushState(m_aryBitArrayStates[z]);
    }

    m_spUnBitArray->FlushBitArray();
    m_nLastX = 0;
}

void CAPEDecompressCore::EndFrame()
{
    // finalize
    m_spUnBitArray->Finalize();

    // check the CRC
    m_nCRC = m_nCRC ^ 0xFFFFFFFF;
    m_nCRC >>= 1;
    if (m_nCRC != m_nStoredCRC)
    {
        // error
        m_bErrorDecodingCurrentFrame = true;
    }
}

void CAPEDecompressCore::WaitUntilReady()
{
    m_semReady.Wait();
}

void CAPEDecompressCore::Exit()
{
    m_bExit = true;

    m_semProcess.Post();
}

}
