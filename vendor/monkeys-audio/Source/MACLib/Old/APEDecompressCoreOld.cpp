#include "All.h"
#ifdef APE_BACKWARDS_COMPATIBILITY

#include "UnMACOld.h"
#include "APEDecompressCoreOld.h"
#include "APEInfo.h"
#include "AntiPredictorOld.h"
#include "Prepare.h"

namespace APE
{

CAPEDecompressCoreOld::CAPEDecompressCoreOld(IAPEDecompress * pAPEDecompress)
{
    m_pAPEDecompress = pAPEDecompress;

    // initialize the bit array
    m_spUnBitArray.Assign(CreateUnBitArray(pAPEDecompress, pAPEDecompress->GetIO(), static_cast<intn>(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION))));

    if (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) >= 3930)
        throw(0);

    m_spAntiPredictorX.Assign(CreateAntiPredictor(static_cast<intn>(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_COMPRESSION_LEVEL)), static_cast<intn>(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION))));
    m_spAntiPredictorY.Assign(CreateAntiPredictor(static_cast<intn>(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_COMPRESSION_LEVEL)), static_cast<intn>(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION))));

    m_spDataX.AllocateArray(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCKS_PER_FRAME) + 16);
    m_spDataY.AllocateArray(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCKS_PER_FRAME) + 16);
    m_spTempData.AllocateArray(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCKS_PER_FRAME) + 16);

    m_nBlocksProcessed = 0;
    m_BitArrayStateX.nKSum = 0;
    m_BitArrayStateY.nKSum = 0;
}

CAPEDecompressCoreOld::~CAPEDecompressCoreOld()
{
}

void CAPEDecompressCoreOld::GenerateDecodedArrays(intn nBlocks, intn nSpecialCodes, intn nFrameIndex)
{
    if (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_CHANNELS) == 2)
    {
        if ((nSpecialCodes & APE_SPECIAL_FRAME_LEFT_SILENCE) && (nSpecialCodes & APE_SPECIAL_FRAME_RIGHT_SILENCE))
        {
            APE_CLEAR_ARRAY(m_spDataX, nBlocks);
            APE_CLEAR_ARRAY(m_spDataY, nBlocks);
        }
        else if (nSpecialCodes & APE_SPECIAL_FRAME_PSEUDO_STEREO)
        {
            GenerateDecodedArray(m_spDataX, static_cast<int>(nBlocks), nFrameIndex, m_spAntiPredictorX);
            APE_CLEAR_ARRAY(m_spDataY, nBlocks);
        }
        else
        {
            GenerateDecodedArray(m_spDataX, static_cast<int>(nBlocks), nFrameIndex, m_spAntiPredictorX);
            GenerateDecodedArray(m_spDataY, static_cast<int>(nBlocks), nFrameIndex, m_spAntiPredictorY);
        }
    }
    else
    {
        if (nSpecialCodes & APE_SPECIAL_FRAME_LEFT_SILENCE)
        {
            APE_CLEAR_ARRAY(m_spDataX, nBlocks);
        }
        else
        {
            GenerateDecodedArray(m_spDataX, static_cast<int>(nBlocks), nFrameIndex, m_spAntiPredictorX);
        }
    }
}


void CAPEDecompressCoreOld::GenerateDecodedArray(int * pInputArray, int nNumberElements, intn nFrameIndex, CAntiPredictor * pAntiPredictor)
{
    const intn nFrameBytes = static_cast<intn>(m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FRAME_BYTES, nFrameIndex));
    if (nFrameBytes <= 0)
        throw(static_cast<intn>(APE_ERROR_INVALID_INPUT_FILE));

    // run the prediction sequence
    switch (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_COMPRESSION_LEVEL))
    {
        case APE_COMPRESSION_LEVEL_FAST:
            if (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) < 3320)
            {
                m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
                pAntiPredictor->AntiPredict(m_spTempData, pInputArray, nNumberElements);
            }
            else
            {
                m_spUnBitArray->GenerateArray(pInputArray, nNumberElements, nFrameBytes);
                pAntiPredictor->AntiPredict(pInputArray, APE_NULL, nNumberElements);
            }

            break;

        case APE_COMPRESSION_LEVEL_NORMAL:
        {
            // get the array from the bitstream
            m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
            pAntiPredictor->AntiPredict(m_spTempData, pInputArray, nNumberElements);
            break;
        }

        case APE_COMPRESSION_LEVEL_HIGH:
            // get the array from the bitstream
            m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
            pAntiPredictor->AntiPredict(m_spTempData, pInputArray, nNumberElements);
            break;

        case APE_COMPRESSION_LEVEL_EXTRA_HIGH:

            int64 aryCoefficientsA[64], aryCoefficientsB[64];
            APE_CLEAR(aryCoefficientsA); // clear to make Clang happy
            APE_CLEAR(aryCoefficientsB); // clear to make Clang happy
            uint32 nNumberOfCoefficients;

            #define GET_COEFFICIENTS(NumberOfCoefficientsBits, ValueBits)                                            \
                nNumberOfCoefficients = static_cast<uint32>(m_spUnBitArray->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_X_BITS, NumberOfCoefficientsBits));        \
                for (unsigned int z = 0; z <= nNumberOfCoefficients; z++)                                            \
                {                                                                                                    \
                    aryCoefficientsA[z] = m_spUnBitArray->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_X_BITS, ValueBits);        \
                    aryCoefficientsB[z] = m_spUnBitArray->DecodeValue(CUnBitArrayBase::DECODE_VALUE_METHOD_X_BITS, ValueBits);        \
                }                                                                                                    \

            if (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) < 3320)
            {
                GET_COEFFICIENTS(4, 6)
                m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
                static_cast<CAntiPredictorExtraHigh0000To3320 *>(pAntiPredictor)->AntiPredictCustom(m_spTempData, pInputArray, nNumberElements, static_cast<int>(nNumberOfCoefficients), &aryCoefficientsA[0], &aryCoefficientsB[0]);
            }
            else if (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) < 3600)
            {
                GET_COEFFICIENTS(3, 5)
                m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
                static_cast<CAntiPredictorExtraHigh3320To3600 *>(pAntiPredictor)->AntiPredictCustom(m_spTempData, pInputArray, nNumberElements, static_cast<int>(nNumberOfCoefficients), &aryCoefficientsA[0], &aryCoefficientsB[0]);
            }
            else if (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) < 3700)
            {
                GET_COEFFICIENTS(3, 6)
                m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
                static_cast<CAntiPredictorExtraHigh3600To3700 *>(pAntiPredictor)->AntiPredictCustom(m_spTempData, pInputArray, nNumberElements, static_cast<int>(nNumberOfCoefficients), &aryCoefficientsA[0], &aryCoefficientsB[0]);
            }
            else if (m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) < 3800)
            {
                GET_COEFFICIENTS(3, 6)
                m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
                static_cast<CAntiPredictorExtraHigh3700To3800 *>(pAntiPredictor)->AntiPredictCustom(m_spTempData, pInputArray, nNumberElements, static_cast<int>(nNumberOfCoefficients), &aryCoefficientsA[0], &aryCoefficientsB[0]);
            }
            else
            {
                m_spUnBitArray->GenerateArray(m_spTempData, nNumberElements, nFrameBytes);
                static_cast<CAntiPredictorExtraHigh3800To3929 *>(pAntiPredictor)->AntiPredictCustom(m_spTempData, pInputArray, nNumberElements, static_cast<intn>(m_pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION)));
            }

            break;
        default:
            // this shouldn't hit, but just to handle all cases we'll put it here
            throw(static_cast<intn>(APE_ERROR_INVALID_INPUT_FILE));

    }
}

}

#endif // #ifdef APE_BACKWARDS_COMPATIBILITY
