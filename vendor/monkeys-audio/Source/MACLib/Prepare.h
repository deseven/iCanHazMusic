#pragma once

namespace APE
{

#define APE_SPECIAL_FRAME_MONO_SILENCE              1
#define APE_SPECIAL_FRAME_LEFT_SILENCE              1
#define APE_SPECIAL_FRAME_RIGHT_SILENCE             2
#define APE_SPECIAL_FRAME_PSEUDO_STEREO             4

/**************************************************************************************************
Manage the preparation stage of compression and decompression

Tasks:

1) convert data to 32-bit
2) convert L,R to X,Y
3) calculate the CRC
4) do simple analysis
**************************************************************************************************/

class IAPEIO;
class IPredictorDecompress;

#if APE_BYTE_ORDER == APE_LITTLE_ENDIAN
    #define APE_24_SHIFT_1ST 0
    #define APE_24_SHIFT_2ND 8
    #define APE_24_SHIFT_3RD 16
#else
    #define APE_24_SHIFT_1ST 16
    #define APE_24_SHIFT_2ND 8
    #define APE_24_SHIFT_3RD 0
#endif

class CPrepare
{
public:
    int Prepare(const unsigned char * pRawData, int nBytes, const WAVEFORMATEX * pWaveFormatEx, int * pOutput, int nFrameBlocks, unsigned int * pCRC, int * pSpecialCodes);
    void Unprepare(int * paryValues, const WAVEFORMATEX * pWaveFormatEx, unsigned char * pOutput);
};

}
