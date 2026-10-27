#include "All.h"
#ifdef APE_BACKWARDS_COMPATIBILITY

#include "APEInfo.h"
#include "UnMACOld.h"
#include "Prepare.h"
#include "APEDecompressCoreOld.h"
#include "CRC.h"
#include "GlobalFunctions.h"

namespace APE
{
/**************************************************************************************************
CUnMACOld class construction
**************************************************************************************************/
CUnMACOld::CUnMACOld()
{
    // initialize member variables
    m_bInitialized = false;
    m_LastDecodedFrameIndex = -1;

    m_nBlocksProcessed = 0;
    m_nCRC = 0;
    m_nStoredCRC = 0;
}

/**************************************************************************************************
CUnMACOld class destruction
**************************************************************************************************/
CUnMACOld::~CUnMACOld()
{
    // uninitialize the decoder in case it isn't already
    Uninitialize();
}

/**************************************************************************************************
Initialize
**************************************************************************************************/
int CUnMACOld::Initialize(IAPEDecompress * pAPEDecompress)
{
    // uninitialize if it is currently initialized
    if (m_bInitialized)
        Uninitialize();

    if (pAPEDecompress == APE_NULL)
    {
        Uninitialize();
        return APE_ERROR_INITIALIZING_UNMAC;
    }

    // set the member pointer to the IAPEDecompress class
    m_spAPEDecompress.Assign(pAPEDecompress, false, false);

    // set the last decode frame to -1 so it forces a seek on start
    m_LastDecodedFrameIndex = -1;

    m_spAPEDecompressCore.Assign(new CAPEDecompressCoreOld(pAPEDecompress));
    m_spPrepare.Assign(new CPrepare);

    // set the initialized flag to true
    m_bInitialized = true;

    // get the format
    m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAVEFORMATEX, APE_POINTER_TO_INT64(&m_wfeInput));

    // return a successful value
    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Uninitialize
**************************************************************************************************/
int CUnMACOld::Uninitialize()
{
    if (m_bInitialized)
    {
        m_spAPEDecompressCore.Delete();
        m_spPrepare.Delete();

        // clear the APE info pointer
        m_spAPEDecompress.Delete();

        // set the last decoded frame again
        m_LastDecodedFrameIndex = -1;

        // set the initialized flag to false
        m_bInitialized = false;
    }

    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Decompress frame
**************************************************************************************************/
intn CUnMACOld::DecompressFrame(unsigned char * pOutputData, int32 nFrameIndex, int * pErrorCode)
{
    try
    {
        // error check the parameters (too high of a frame index, etc.)
        if (nFrameIndex >= m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_TOTAL_FRAMES)) { return APE_ERROR_SUCCESS; }

        // get the number of samples in the frame
        int nBlocks = 0;
        nBlocks = ((static_cast<int64>(nFrameIndex) + 1) >= m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_TOTAL_FRAMES)) ? static_cast<int>(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FINAL_FRAME_BLOCKS)) : static_cast<int>(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCKS_PER_FRAME));
        if (nBlocks == 0)
        {
            if (pErrorCode)
                *pErrorCode = APE_ERROR_UNDEFINED;
            return -1; // nothing to do (file must be zero length) (have to return error)
        }

        // take care of seeking and frame alignment
        if (SeekToFrame(nFrameIndex) != 0)
        {
            if (pErrorCode)
                *pErrorCode = APE_ERROR_UNDEFINED;
            return -1;
        }

        // get the checksum
        unsigned int nSpecialCodes = 0;
        uint32 nStoredCRC = 0;

        if (!APE_GET_USES_CRC(m_spAPEDecompress))
        {
            nStoredCRC = static_cast<uint32>(m_spAPEDecompressCore->GetUnBitArrray()->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_UNSIGNED_RICE, 30));
            if (nStoredCRC == 0)
            {
                nSpecialCodes = APE_SPECIAL_FRAME_LEFT_SILENCE | APE_SPECIAL_FRAME_RIGHT_SILENCE;
            }
        }
        else
        {
            nStoredCRC = static_cast<uint32>(m_spAPEDecompressCore->GetUnBitArrray()->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_UNSIGNED_INT));

            // get any 'special' codes if the file uses them (for silence, false stereo, etc.)
            nSpecialCodes = 0;
            if (APE_GET_USES_SPECIAL_FRAMES(m_spAPEDecompress))
            {
                if (nStoredCRC & 0x80000000)
                {
                    nSpecialCodes = static_cast<unsigned int>(m_spAPEDecompressCore->GetUnBitArrray()->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_UNSIGNED_INT));
                }
                nStoredCRC &= 0x7FFFFFFF;
            }
        }

        // the CRC that will be figured during decompression
        uint32 CRC = 0xFFFFFFFF;

        // decompress and convert from (x,y) -> (l,r)
        // sort of int and ugly.... sorry
        if (m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_CHANNELS) == 2)
        {
            m_spAPEDecompressCore->GenerateDecodedArrays(nBlocks, static_cast<intn>(nSpecialCodes), static_cast<intn>(nFrameIndex));

            WAVEFORMATEX WaveFormatEx; m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAVEFORMATEX, APE_POINTER_TO_INT64(&WaveFormatEx));
            UnprepareStereo(m_spAPEDecompressCore->GetDataX(), m_spAPEDecompressCore->GetDataY(), nBlocks, &WaveFormatEx,
                pOutputData, static_cast<unsigned int *>(&CRC), static_cast<int>(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION)));
        }
        else if (m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_CHANNELS) == 1)
        {
            m_spAPEDecompressCore->GenerateDecodedArrays(nBlocks, static_cast<intn>(nSpecialCodes), static_cast<intn>(nFrameIndex));

            WAVEFORMATEX WaveFormatEx; m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAVEFORMATEX, APE_POINTER_TO_INT64(&WaveFormatEx));
            UnprepareMono(m_spAPEDecompressCore->GetDataX(), nBlocks, &WaveFormatEx,
                pOutputData, static_cast<unsigned int *>(&CRC), static_cast<int>(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION)));
        }

        if (APE_GET_USES_SPECIAL_FRAMES(m_spAPEDecompress))
        {
            CRC >>= 1;
        }

        // check the CRC
        if (!APE_GET_USES_CRC(m_spAPEDecompress))
        {
            const uint32 nChecksum = CalculateOldChecksum(m_spAPEDecompressCore->GetDataX(), m_spAPEDecompressCore->GetDataY(), static_cast<intn>(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_CHANNELS)), nBlocks);
            if (nChecksum != nStoredCRC)
            {
                if (pErrorCode)
                    *pErrorCode = APE_ERROR_INVALID_CHECKSUM;
                return -1;
            }
        }
        else
        {
            if (CRC != nStoredCRC)
            {
                if (pErrorCode)
                    *pErrorCode = APE_ERROR_INVALID_CHECKSUM;
                return -1;
            }
        }

        if (pErrorCode)
            *pErrorCode = APE_ERROR_SUCCESS;
        m_LastDecodedFrameIndex = nFrameIndex;
        return nBlocks;
    }
    catch (const intn nErrorCode)
    {
        if (pErrorCode)
            *pErrorCode = static_cast<int>(nErrorCode);
        return -1; // error state
    }
    catch (...)
    {
        if (pErrorCode)
            *pErrorCode = APE_ERROR_INVALID_INPUT_FILE;
        return -1; // error state
    }
}

/**************************************************************************************************
Seek to the proper frame (if necessary) and do any alignment of the bit array
**************************************************************************************************/
int CUnMACOld::SeekToFrame(intn FrameIndex)
{
    if (APE_GET_FRAMES_START_ON_BYTES_BOUNDARIES(m_spAPEDecompress))
    {
        if ((m_LastDecodedFrameIndex == -1) || ((FrameIndex - 1) != m_LastDecodedFrameIndex))
        {
            const int64 nSeekRemainder = (m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_SEEK_BYTE, FrameIndex) - m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_SEEK_BYTE, 0)) % 4;
            m_spAPEDecompressCore->GetUnBitArrray()->FillAndResetBitArray(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_SEEK_BYTE, FrameIndex) - nSeekRemainder, nSeekRemainder * 8);
        }
        else
        {
            m_spAPEDecompressCore->GetUnBitArrray()->AdvanceToByteBoundary();
        }
    }
    else
    {
        if ((m_LastDecodedFrameIndex == -1) || ((FrameIndex - 1) != m_LastDecodedFrameIndex))
        {
            m_spAPEDecompressCore->GetUnBitArrray()->FillAndResetBitArray(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_SEEK_BYTE, FrameIndex), static_cast<intn>(m_spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_SEEK_BIT, FrameIndex)));
        }
    }

    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Figures the old checksum using the X,Y data
**************************************************************************************************/
uint32 CUnMACOld::CalculateOldChecksum(const int * pDataX, const int * pDataY, intn nChannels, intn nBlocks)
{
    uint32 nChecksum = 0;

    if (nChannels == 2)
    {
        for (int z = 0; z < nBlocks; z++)
        {
            const int R = pDataX[z] - (pDataY[z] / 2);
            const int L = R + pDataY[z];
            nChecksum += static_cast<uint32>(labs(R) + labs(L));
        }
    }
    else if (nChannels == 1)
    {
        for (int z = 0; z < nBlocks; z++)
            nChecksum += static_cast<uint32>(labs(pDataX[z]));
    }

    return nChecksum;
}

/**************************************************************************************************
Unprepare
**************************************************************************************************/
void CUnMACOld::UnprepareMono(int * pInputX, int nBlocks, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pRawData, unsigned int * pCRC, int nFileVersion)
{
    // convert to raw data
    if (pWaveFormatEx->wBitsPerSample == 8)
    {
        unsigned char * R = static_cast<unsigned char *>(&pRawData[0]);

        if (nFileVersion > 3830)
        {
            for (int SampleIndex = 0; SampleIndex < nBlocks; SampleIndex++, R++)
                *R = static_cast<unsigned char>(pInputX[SampleIndex] + 128);
        }
        else
        {
            for (int SampleIndex = 0; SampleIndex < nBlocks; SampleIndex++, R++)
                *R = static_cast<unsigned char>(pInputX[SampleIndex]);
        }
    }
    else if (pWaveFormatEx->wBitsPerSample == 24)
    {
        unsigned char * Buffer = static_cast<unsigned char *>(&pRawData[0]);
        int32 RV;
        for (int SampleIndex = 0; SampleIndex < nBlocks; SampleIndex++)
        {
            RV = pInputX[SampleIndex];

            uint32 nTemp = 0;
            if (RV < 0)
                nTemp = static_cast<uint32>((RV + 0x800000) | 0x800000);
            else
                nTemp = static_cast<uint32>(RV);

            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);
        }
    }
    else
    {
        int16 * pBuffer16 = reinterpret_cast<int16 *>(&pRawData[0]);
        for (int SampleIndex = 0; SampleIndex < nBlocks; SampleIndex++)
        {
            *pBuffer16 = static_cast<int16>(pInputX[SampleIndex]); pBuffer16++;
        }
    }

    // calculate CRC
    UnprepareCRC(nBlocks, pWaveFormatEx, pRawData, pCRC);
}

void CUnMACOld::UnprepareStereo(int * pInputX, int * pInputY, int nBlocks, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pRawData, unsigned int * pCRC, int nFileVersion)
{
    // decompress and convert from (x,y) -> (l,r)

    // convert the x,y data to raw data
    if (pWaveFormatEx->wBitsPerSample == 16)
    {
        int16 R;
        int16 * pBuffer16 = reinterpret_cast<int16 *>(&pRawData[0]);
        int * pX = static_cast<int *>(pInputX);
        int * pY = static_cast<int *>(pInputY);

        for (; pX < &pInputX[nBlocks]; pX++, pY++)
        {
            R = static_cast<int16>(*pX - (*pY / 2));

            *pBuffer16 = static_cast<int16>(R); pBuffer16++;
            *pBuffer16 = static_cast<int16>(R + *pY); pBuffer16++;
        }
    }
    else if (pWaveFormatEx->wBitsPerSample == 8)
    {
        unsigned char * R = static_cast<unsigned char *>(&pRawData[0]);
        unsigned char * L = static_cast<unsigned char *>(&pRawData[1]);

        if (nFileVersion > 3830)
        {
            for (int SampleIndex = 0; SampleIndex < nBlocks; SampleIndex++, L += 2, R += 2)
            {
                *R = static_cast<unsigned char>(pInputX[SampleIndex] - (pInputY[SampleIndex] / 2) + 128);
                *L = static_cast<unsigned char>(*R + pInputY[SampleIndex]);
            }
        }
        else
        {
            for (int SampleIndex = 0; SampleIndex < nBlocks; SampleIndex++, L += 2, R += 2)
            {
                *R = static_cast<unsigned char>(pInputX[SampleIndex] - (pInputY[SampleIndex] / 2));
                *L = static_cast<unsigned char>(*R + pInputY[SampleIndex]);
            }
        }
    }
    else if (pWaveFormatEx->wBitsPerSample == 24)
    {
        unsigned char * Buffer = static_cast<unsigned char *>(&pRawData[0]);
        int32 RV, LV;

        for (int SampleIndex = 0; SampleIndex < nBlocks; SampleIndex++)
        {
            RV = pInputX[SampleIndex] - (pInputY[SampleIndex] / 2);
            LV = RV + pInputY[SampleIndex];

            uint32 nTemp = 0;
            if (RV < 0)
                nTemp = (static_cast<uint32>((RV + 0x800000)) | 0x800000);
            else
                nTemp = static_cast<uint32>(RV);

            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);

            if (LV < 0)
                nTemp = (static_cast<uint32>((LV + 0x800000)) | 0x800000);
            else
                nTemp = static_cast<uint32>(LV);

            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
            *Buffer++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);
        }
    }

    // calculate CRC
    UnprepareCRC(nBlocks, pWaveFormatEx, pRawData, pCRC);
}

void CUnMACOld::UnprepareCRC(int nBlocks, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pRawData, unsigned int * pCRC)
{
    uint32 CRC = 0xFFFFFFFF;

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    SwitchBufferBytes(const_cast<unsigned char *>(pRawData), pWaveFormatEx->wBitsPerSample / 8, nBlocks * pWaveFormatEx->nChannels);
#endif

    CRC = CRC_update(CRC, pRawData, static_cast<int>(nBlocks * pWaveFormatEx->nChannels * (pWaveFormatEx->wBitsPerSample / 8)));
    CRC = CRC ^ 0xFFFFFFFF;

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    SwitchBufferBytes(const_cast<unsigned char *>(pRawData), pWaveFormatEx->wBitsPerSample / 8, nBlocks * pWaveFormatEx->nChannels);
#endif

    * pCRC = CRC;
}

}
#endif // #ifdef APE_BACKWARDS_COMPATIBILITY
