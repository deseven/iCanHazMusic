#include "All.h"
#include "Prepare.h"
#include "CRC.h"
#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    #include "GlobalFunctions.h"
#endif

namespace APE
{

int CPrepare::Prepare(const unsigned char * pRawData, int nBytes, const WAVEFORMATEX * pWaveFormatEx, int * pOutput, int nFrameBlocks, unsigned int * pCRC, int * pSpecialCodes)
{
    // error check the parameters
    if (pRawData == APE_NULL || pWaveFormatEx == APE_NULL)
        return APE_ERROR_BAD_PARAMETER;

    // initialize the pointers that got passed in
    *pCRC = 0xFFFFFFFF;
    *pSpecialCodes = 0;

    // variables
    uint32 CRC = 0xFFFFFFFF;
    const int nTotalBlocks = nBytes / pWaveFormatEx->nBlockAlign;
    int R, L;

    // calculate CRC
#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    SwitchBufferBytes(const_cast<unsigned char *>(pRawData), pWaveFormatEx->wBitsPerSample / 8, nTotalBlocks * pWaveFormatEx->nChannels);
#endif

    CRC = CRC_update(CRC, pRawData, nTotalBlocks * pWaveFormatEx->nChannels * (pWaveFormatEx->wBitsPerSample / 8));

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    SwitchBufferBytes(const_cast<unsigned char *>(pRawData), pWaveFormatEx->wBitsPerSample / 8, nTotalBlocks * pWaveFormatEx->nChannels);
#endif

    // the prepare code
    if (pWaveFormatEx->wBitsPerSample == 32)
    {
        const int * pData = reinterpret_cast<const int *>(pRawData);
        if (pWaveFormatEx->nChannels == 2)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                R = *pData++;
                L = *pData++;

                pOutput[nFrameBlocks + nBlockIndex] = L - R;
                pOutput[nBlockIndex] = R + (pOutput[nFrameBlocks + nBlockIndex] / 2);
            }
        }
        else
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    const int nValue = *pData;
                    pData += 1;

                    // convert to x,y
                    pOutput[(nChannel * nFrameBlocks) + nBlockIndex] = nValue;
                }
            }
        }
    }
    else if (pWaveFormatEx->wBitsPerSample == 8)
    {
        if (pWaveFormatEx->nChannels == 2)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                R = static_cast<int>(*pRawData++) - 128;
                L = static_cast<int>(*pRawData++) - 128;

                // convert to x,y
                pOutput[nFrameBlocks + nBlockIndex] = L - R;
                pOutput[nBlockIndex] = R + (pOutput[nFrameBlocks + nBlockIndex] / 2);
            }
        }
        else if (pWaveFormatEx->nChannels == 1)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                R = static_cast<int>(*pRawData++) - 128;

                // convert to x,y
                pOutput[nBlockIndex] = R;
            }
        }
        else
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    R = static_cast<int>(*pRawData++) - 128;

                    pOutput[(nChannel * nFrameBlocks) + nBlockIndex] = R;
                }
            }
        }
    }
    else if (pWaveFormatEx->wBitsPerSample == 24)
    {
        if (pWaveFormatEx->nChannels == 4)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                // left and right (use mid-side)
                {
                    // get the value
                    R = 0;
                    R |= (*pRawData++ << APE_24_SHIFT_1ST);
                    R |= (*pRawData++ << APE_24_SHIFT_2ND);
                    R |= (*pRawData++ << APE_24_SHIFT_3RD);
                    R = (R << 8) >> 8;

                    L = 0;
                    L |= (*pRawData++ << APE_24_SHIFT_1ST);
                    L |= (*pRawData++ << APE_24_SHIFT_2ND);
                    L |= (*pRawData++ << APE_24_SHIFT_3RD);
                    L = (L << 8) >> 8;

                    pOutput[(1 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(0 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(1 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // surrounds
                {
                    // get the value
                    R = 0;
                    R |= (*pRawData++ << APE_24_SHIFT_1ST);
                    R |= (*pRawData++ << APE_24_SHIFT_2ND);
                    R |= (*pRawData++ << APE_24_SHIFT_3RD);
                    R = (R << 8) >> 8;

                    L = 0;
                    L |= (*pRawData++ << APE_24_SHIFT_1ST);
                    L |= (*pRawData++ << APE_24_SHIFT_2ND);
                    L |= (*pRawData++ << APE_24_SHIFT_3RD);
                    L = (L << 8) >> 8;

                    pOutput[(3 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(2 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(3 * nFrameBlocks) + nBlockIndex] / 2);
                }
            }
        }
        else if (pWaveFormatEx->nChannels >= 6)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                // left and right (use mid-side)
                {
                    // get the value
                    R = 0;
                    R |= (*pRawData++ << APE_24_SHIFT_1ST);
                    R |= (*pRawData++ << APE_24_SHIFT_2ND);
                    R |= (*pRawData++ << APE_24_SHIFT_3RD);
                    R = (R << 8) >> 8;

                    L = 0;
                    L |= (*pRawData++ << APE_24_SHIFT_1ST);
                    L |= (*pRawData++ << APE_24_SHIFT_2ND);
                    L |= (*pRawData++ << APE_24_SHIFT_3RD);
                    L = (L << 8) >> 8;

                    pOutput[(1 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(0 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(1 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // center and subwoofer
                {
                    // get the value
                    R = 0;
                    R |= (*pRawData++ << APE_24_SHIFT_1ST);
                    R |= (*pRawData++ << APE_24_SHIFT_2ND);
                    R |= (*pRawData++ << APE_24_SHIFT_3RD);
                    R = (R << 8) >> 8;

                    L = 0;
                    L |= (*pRawData++ << APE_24_SHIFT_1ST);
                    L |= (*pRawData++ << APE_24_SHIFT_2ND);
                    L |= (*pRawData++ << APE_24_SHIFT_3RD);
                    L = (L << 8) >> 8;

                    pOutput[(3 * nFrameBlocks) + nBlockIndex] = L;
                    pOutput[(2 * nFrameBlocks) + nBlockIndex] = R;
                }

                // surrounds
                {
                    // get the value
                    R = 0;
                    R |= (*pRawData++ << APE_24_SHIFT_1ST);
                    R |= (*pRawData++ << APE_24_SHIFT_2ND);
                    R |= (*pRawData++ << APE_24_SHIFT_3RD);
                    R = (R << 8) >> 8;

                    L = 0;
                    L |= (*pRawData++ << APE_24_SHIFT_1ST);
                    L |= (*pRawData++ << APE_24_SHIFT_2ND);
                    L |= (*pRawData++ << APE_24_SHIFT_3RD);
                    L = (L << 8) >> 8;

                    pOutput[(5 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(4 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(5 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // rears
                if (pWaveFormatEx->nChannels >= 8)
                {
                    // get the value
                    R = 0;
                    R |= (*pRawData++ << APE_24_SHIFT_1ST);
                    R |= (*pRawData++ << APE_24_SHIFT_2ND);
                    R |= (*pRawData++ << APE_24_SHIFT_3RD);
                    R = (R << 8) >> 8;

                    L = 0;
                    L |= (*pRawData++ << APE_24_SHIFT_1ST);
                    L |= (*pRawData++ << APE_24_SHIFT_2ND);
                    L |= (*pRawData++ << APE_24_SHIFT_3RD);
                    L = (L << 8) >> 8;

                    pOutput[(7 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(6 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(7 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // remaining channels
                const int nStartChannel = (pWaveFormatEx->nChannels == 7) ? 7 : 8;
                for (int nChannel = nStartChannel; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    int nValue = 0;

                    nValue |= (*pRawData++ << APE_24_SHIFT_1ST);
                    nValue |= (*pRawData++ << APE_24_SHIFT_2ND);
                    nValue |= (*pRawData++ << APE_24_SHIFT_3RD);
                    nValue = (nValue << 8) >> 8;

                    // convert to x,y
                    pOutput[(nChannel * nFrameBlocks) + nBlockIndex] = nValue;
                }
            }
        }
        else if (pWaveFormatEx->nChannels == 2)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                R = 0;
                R |= (*pRawData++ << APE_24_SHIFT_1ST);
                R |= (*pRawData++ << APE_24_SHIFT_2ND);
                R |= (*pRawData++ << APE_24_SHIFT_3RD);
                R = (R << 8) >> 8;

                L = 0;
                L |= (*pRawData++ << APE_24_SHIFT_1ST);
                L |= (*pRawData++ << APE_24_SHIFT_2ND);
                L |= (*pRawData++ << APE_24_SHIFT_3RD);
                L = (L << 8) >> 8;

                // convert to x,y
                pOutput[nFrameBlocks + nBlockIndex] = L - R;
                pOutput[nBlockIndex] = R + (pOutput[nFrameBlocks + nBlockIndex] / 2);
            }
        }
        else if (pWaveFormatEx->nChannels == 1)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                R = 0;
                R |= (*pRawData++ << APE_24_SHIFT_1ST);
                R |= (*pRawData++ << APE_24_SHIFT_2ND);
                R |= (*pRawData++ << APE_24_SHIFT_3RD);
                R = (R << 8) >> 8;

                // convert to x,y
                pOutput[nBlockIndex] = R;
            }
        }
        else
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    int nValue = 0;

                    nValue |= (*pRawData++ << APE_24_SHIFT_1ST);
                    nValue |= (*pRawData++ << APE_24_SHIFT_2ND);
                    nValue |= (*pRawData++ << APE_24_SHIFT_3RD);
                    nValue = (nValue << 8) >> 8;

                    pOutput[(nChannel * nFrameBlocks) + nBlockIndex] = nValue;
                }
            }
        }
    }
    else if (pWaveFormatEx->wBitsPerSample == 16)
    {
        const int16 * pRawData16 = reinterpret_cast<const int16 *>(pRawData);

        if (pWaveFormatEx->nChannels == 4)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                // left and right (use mid-side)
                {
                    // get the value
                    R = static_cast<int>(*pRawData16);
                    pRawData16++;
                    L = static_cast<int>(*pRawData16);
                    pRawData16++;

                    pOutput[(1 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(0 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(1 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // surrounds
                {
                    // get the value
                    R = static_cast<int>(*pRawData16);
                    pRawData16++;
                    L = static_cast<int>(*pRawData16);
                    pRawData16++;

                    pOutput[(3 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(2 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(3 * nFrameBlocks) + nBlockIndex] / 2);
                }
            }
        }
        else if (pWaveFormatEx->nChannels >= 6)
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                // left and right (use mid-side)
                {
                    // get the value
                    R = static_cast<int>(*pRawData16);
                    pRawData16++;
                    L = static_cast<int>(*pRawData16);
                    pRawData16++;

                    pOutput[(1 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(0 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(1 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // center and subwoofer
                {
                    // get the value
                    R = static_cast<int>(*pRawData16);
                    pRawData16++;
                    L = static_cast<int>(*pRawData16);
                    pRawData16++;

                    pOutput[(3 * nFrameBlocks) + nBlockIndex] = L;
                    pOutput[(2 * nFrameBlocks) + nBlockIndex] = R;
                }

                // surrounds
                {
                    // get the value
                    R = static_cast<int>(*pRawData16);
                    pRawData16++;
                    L = static_cast<int>(*pRawData16);
                    pRawData16++;

                    pOutput[(5 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(4 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(5 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // rears
                if (pWaveFormatEx->nChannels >= 8)
                {
                    // get the value
                    R = static_cast<int>(*pRawData16);
                    pRawData16++;
                    L = static_cast<int>(*pRawData16);
                    pRawData16++;

                    pOutput[(7 * nFrameBlocks) + nBlockIndex] = L - R;
                    pOutput[(6 * nFrameBlocks) + nBlockIndex] = R + (pOutput[(7 * nFrameBlocks) + nBlockIndex] / 2);
                }

                // remaining
                const int nStartChannel = (pWaveFormatEx->nChannels == 7) ? 7 : 8;
                for (int nChannel = nStartChannel; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    // get the value
                    const int nValue = static_cast<int>(*pRawData16);
                    pRawData16++;

                    // convert to x,y
                    pOutput[(nChannel * nFrameBlocks) + nBlockIndex] = nValue;
                }
            }
        }
        else if (pWaveFormatEx->nChannels == 2)
        {
            int LPeak = 0;
            int RPeak = 0;
            int nBlockIndex = 0;
            for (nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                R = static_cast<int>(*pRawData16); pRawData16++;
                L = static_cast<int>(*pRawData16); pRawData16++;

                // check the peak
                if (abs(L) > LPeak)
                    LPeak = static_cast<int>(abs(L));
                if (abs(R) > RPeak)
                    RPeak = static_cast<int>(abs(R));

                // convert to x,y
                pOutput[nFrameBlocks + nBlockIndex] = L - R;
                pOutput[nBlockIndex] = R + (pOutput[nFrameBlocks + nBlockIndex] / 2);
            }

            if (LPeak == 0) { *pSpecialCodes |= APE_SPECIAL_FRAME_LEFT_SILENCE; }
            if (RPeak == 0) { *pSpecialCodes |= APE_SPECIAL_FRAME_RIGHT_SILENCE; }

            // check for pseudo-stereo files
            nBlockIndex = 0;
            while (pOutput[nFrameBlocks + nBlockIndex++] == 0)
            {
                if (nBlockIndex == (nBytes / 4))
                {
                    *pSpecialCodes |= APE_SPECIAL_FRAME_PSEUDO_STEREO;
                    break;
                }
            }
        }
        else if (pWaveFormatEx->nChannels == 1)
        {
            int nPeak = 0;
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                R = static_cast<int>(*pRawData16); pRawData16++;

                // check the peak
                if (abs(R) > nPeak)
                    nPeak = static_cast<int>(abs(R));

                //convert to x,y
                pOutput[nBlockIndex] = R;
            }

            if (nPeak == 0) { *pSpecialCodes |= APE_SPECIAL_FRAME_MONO_SILENCE; }
        }
        else
        {
            for (int nBlockIndex = 0; nBlockIndex < nTotalBlocks; nBlockIndex++)
            {
                for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    R = static_cast<int>(*pRawData16); pRawData16++;

                    pOutput[(nChannel * nFrameBlocks) + nBlockIndex] = R;
                }
            }
        }
    }

    CRC = CRC ^ 0xFFFFFFFF;

    // add the special code
    CRC >>= 1;

    if (*pSpecialCodes != 0)
    {
        CRC |= (static_cast<unsigned int>(1) << 31);
    }

    *pCRC = CRC;

    return APE_ERROR_SUCCESS;
}

void CPrepare::Unprepare(int * paryValues, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pOutput)
{
    // decompress and convert from (x,y) -> (l,r)
    if (pWaveFormatEx->wBitsPerSample == 32)
    {
        int * pOutput32 = reinterpret_cast<int *>(pOutput);
        if (pWaveFormatEx->nChannels == 2)
        {
            // get the right and left values
            int nR = static_cast<int>((paryValues[0] - (paryValues[1] / 2)));
            int nL = static_cast<int>(nR + paryValues[1]);
            *pOutput32 = nR; pOutput32++;
            *pOutput32 = nL; //pOutput32++; not read any more
        }
        else
        {
            for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
            {
                int nValue = static_cast<int>(paryValues[nChannel]);
                *pOutput32 = nValue;
                pOutput32++;
            }
        }
    }
    else if (pWaveFormatEx->nChannels > 2)
    {
        if (pWaveFormatEx->wBitsPerSample == 24)
        {
            if (pWaveFormatEx->nChannels == 4)
            {
                // get left and right channels
                {
                    const int nL = static_cast<int>(paryValues[0] - (paryValues[1] / 2));
                    const int nR = nL + static_cast<int>(paryValues[1]);

                    uint32 nTempL = static_cast<uint32>(nL);
                    uint32 nTempR = static_cast<uint32>(nR);

                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_3RD) & 0xFF);

                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_3RD) & 0xFF);
                }

                // surrounds
                {
                    const int nL = static_cast<int>(paryValues[2] - (paryValues[3] / 2));
                    const int nR = nL + static_cast<int>(paryValues[3]);

                    uint32 nTempL = static_cast<uint32>(nL);
                    uint32 nTempR = static_cast<uint32>(nR);

                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_3RD) & 0xFF);

                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_3RD) & 0xFF);
                }
            }
            else if (pWaveFormatEx->nChannels >= 6)
            {
                // get left and right channels
                {
                    const int nL = static_cast<int>(paryValues[0] - (paryValues[1] / 2));
                    const int nR = static_cast<int>(nL + paryValues[1]);

                    uint32 nTempL = static_cast<uint32>(nL);
                    uint32 nTempR = static_cast<uint32>(nR);

                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_3RD) & 0xFF);

                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_3RD) & 0xFF);
                }

                // center and subwoofer channels
                {
                    const int nL = static_cast<int>(paryValues[2]);
                    const int nR = static_cast<int>(paryValues[3]);

                    uint32 nTempL = static_cast<uint32>(nL);
                    uint32 nTempR = static_cast<uint32>(nR);

                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_3RD) & 0xFF);

                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_3RD) & 0xFF);
                }

                // surrounds
                {
                    const int nL = static_cast<int>(paryValues[4] - (paryValues[5] / 2));
                    const int nR = static_cast<int>(nL + paryValues[5]);

                    uint32 nTempL = static_cast<uint32>(nL);
                    uint32 nTempR = static_cast<uint32>(nR);

                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_3RD) & 0xFF);

                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_3RD) & 0xFF);
                }

                // rears
                if (pWaveFormatEx->nChannels >= 8)
                {
                    const int nL = static_cast<int>(paryValues[6] - (paryValues[7] / 2));
                    const int nR = static_cast<int>(nL + paryValues[7]);

                    uint32 nTempL = static_cast<uint32>(nL);
                    uint32 nTempR = static_cast<uint32>(nR);

                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempL >> APE_24_SHIFT_3RD) & 0xFF);

                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTempR >> APE_24_SHIFT_3RD) & 0xFF);
                }

                const int nStartChannel = (pWaveFormatEx->nChannels == 7) ? 7 : 8;
                for (int nChannel = nStartChannel; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    const int nValue = static_cast<int>(paryValues[nChannel]);

                    uint32 nTemp = static_cast<uint32>(nValue);

                    *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);
                }
            }
            else
            {
                for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    const int nValue = static_cast<int>(paryValues[nChannel]);

                    uint32 nTemp = static_cast<uint32>(nValue);

                    *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
                    *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);
                }
             }
        }
        else if (pWaveFormatEx->wBitsPerSample == 16)
        {
            int16 * pOutput16 = reinterpret_cast<int16 *>(pOutput);
            if (pWaveFormatEx->nChannels == 4)
            {
                // get left and right channels
                {
                    int nR = static_cast<int>(paryValues[0] - (paryValues[1] / 2));
                    int nL = static_cast<int>(nR + paryValues[1]);

                    // error check (for overflows)
                    if ((nR < -32768) || (nR > 32767) || (nL < -32768) || (nL > 32767))
                    {
                        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
                    }

                    *pOutput16 = static_cast<int16>(nR); pOutput16++;
                    *pOutput16 = static_cast<int16>(nL); pOutput16++;
                }

                // get surrounds
                {
                    int nR = static_cast<int>(paryValues[2] - (paryValues[3] / 2));
                    int nL = static_cast<int>(nR + paryValues[3]);

                    // error check (for overflows)
                    if ((nR < -32768) || (nR > 32767) || (nL < -32768) || (nL > 32767))
                    {
                        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
                    }

                    *pOutput16 = static_cast<int16>(nR); pOutput16++;
                    *pOutput16 = static_cast<int16>(nL); //pOutput16++; not read any more
                }
            }
            else if (pWaveFormatEx->nChannels >= 6)
            {
                // get left and right channels
                {
                    int nR = static_cast<int>(paryValues[0] - (paryValues[1] / 2));
                    int nL = static_cast<int>(nR + paryValues[1]);

                    // error check (for overflows)
                    if ((nR < -32768) || (nR > 32767) || (nL < -32768) || (nL > 32767))
                    {
                        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
                    }

                    *pOutput16 = static_cast<int16>(nR); pOutput16++;
                    *pOutput16 = static_cast<int16>(nL); pOutput16++;
                }

                // get center and subwoofer channels
                {
                    int nR = static_cast<int>(paryValues[2]);
                    int nL = static_cast<int>(paryValues[3]);

                    // error check (for overflows)
                    if ((nR < -32768) || (nR > 32767) || (nL < -32768) || (nL > 32767))
                    {
                        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
                    }

                    *pOutput16 = static_cast<int16>(nR); pOutput16++;
                    *pOutput16 = static_cast<int16>(nL); pOutput16++;
                }

                // get surrounds
                {
                    int nR = static_cast<int>(paryValues[4] - (paryValues[5] / 2));
                    int nL = static_cast<int>(nR + paryValues[5]);

                    // error check (for overflows)
                    if ((nR < -32768) || (nR > 32767) || (nL < -32768) || (nL > 32767))
                    {
                        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
                    }

                    *pOutput16 = static_cast<int16>(nR); pOutput16++;
                    *pOutput16 = static_cast<int16>(nL); pOutput16++;
                }

                // get rears
                if (pWaveFormatEx->nChannels >= 8)
                {
                    int nR = static_cast<int>(paryValues[6] - (paryValues[7] / 2));
                    int nL = static_cast<int>(nR + paryValues[7]);

                    // error check (for overflows)
                    if ((nR < -32768) || (nR > 32767) || (nL < -32768) || (nL > 32767))
                    {
                        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
                    }

                    *pOutput16 = static_cast<int16>(nR); pOutput16++;
                    *pOutput16 = static_cast<int16>(nL); pOutput16++;
                }

                // remaining
                const int nStartChannel = (pWaveFormatEx->nChannels == 7) ? 7 : 8;
                for (int nChannel = nStartChannel; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    int nValue = static_cast<int>(paryValues[nChannel]);

                    *pOutput16 = static_cast<int16>(nValue); pOutput16++;
                }
            }
            else
            {
                for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
                {
                    int nValue = static_cast<int>(paryValues[nChannel]);
                    *pOutput16 = static_cast<int16>(nValue); pOutput16++;
                }
             }
        }
        else if (pWaveFormatEx->wBitsPerSample == 8)
        {
            for (int nChannel = 0; nChannel < pWaveFormatEx->nChannels; nChannel++)
            {
                unsigned char V = static_cast<unsigned char>(paryValues[nChannel] + 128);
                *pOutput++ = V;
            }
        }
    }
    else if (pWaveFormatEx->nChannels == 2)
    {
        if (pWaveFormatEx->wBitsPerSample == 16)
        {
            // get the right and left values
            int nR = static_cast<int>(paryValues[0] - (paryValues[1] / 2));
            int nL = static_cast<int>(nR + paryValues[1]);

            // error check (for overflows)
            if ((nR < -32768) || (nR > 32767) || (nL < -32768) || (nL > 32767))
            {
                throw(static_cast<intn>(APE_ERROR_UNDEFINED));
            }

            int16 * pOutput16 = reinterpret_cast<int16 *>(pOutput);
            *pOutput16 = static_cast<int16>(nR); pOutput16++;
            *pOutput16 = static_cast<int16>(nL); //pOutput16++; not read any more
        }
        else if (pWaveFormatEx->wBitsPerSample == 8)
        {
            unsigned char R = static_cast<unsigned char>((paryValues[0] - (paryValues[1] / 2) + 128));
            *pOutput++ = R;
            *pOutput++ = static_cast<unsigned char>(R + paryValues[1]);
        }
        else if (pWaveFormatEx->wBitsPerSample == 24)
        {
            int32 RV, LV;

            RV = static_cast<int32>(paryValues[0] - (paryValues[1] / 2));
            LV = static_cast<int32>(RV + paryValues[1]);

            uint32 nTemp = 0;
            if (RV < 0)
                nTemp = (static_cast<uint32>((RV + 0x800000)) | 0x800000);
            else
                nTemp = static_cast<uint32>(RV);

            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);

            if (LV < 0)
                nTemp = (static_cast<uint32>((LV + 0x800000)) | 0x800000);
            else
                nTemp = static_cast<uint32>(LV);

            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);
        }
    }
    else if (pWaveFormatEx->nChannels == 1)
    {
        if (pWaveFormatEx->wBitsPerSample == 16)
        {
            int16 R = static_cast<int16>(paryValues[0]);

            *reinterpret_cast<int16 *>(pOutput) = static_cast<int16>(R); //pOutput += 2; not read any more
        }
        else if (pWaveFormatEx->wBitsPerSample == 8)
        {
            unsigned char R = static_cast<unsigned char>(paryValues[0] + 128);
            *pOutput++ = R;
        }
        else if (pWaveFormatEx->wBitsPerSample == 24)
        {
            const int32 RV = static_cast<int32>(paryValues[0]);

            uint32 nTemp = 0;
            if (RV < 0)
                nTemp = static_cast<uint32>((RV + 0x800000) | 0x800000);
            else
                nTemp = static_cast<uint32>(RV);

            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_1ST) & 0xFF);
            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_2ND) & 0xFF);
            *pOutput++ = static_cast<unsigned char>((nTemp >> APE_24_SHIFT_3RD) & 0xFF);
        }
    }
}

}
