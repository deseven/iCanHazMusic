#pragma once

namespace APE
{

class CAPEDecompressCoreOld
{
public:
    CAPEDecompressCoreOld(IAPEDecompress * pAPEDecompress);
    ~CAPEDecompressCoreOld();

    void GenerateDecodedArrays(intn nBlocks, intn nSpecialCodes, intn nFrameIndex);
    void GenerateDecodedArray(int * pInputArray, int nNumberElements, intn nFrameIndex, CAntiPredictor * pAntiPredictor);

    APE_INLINE int * GetDataX() const { return m_spDataX; }
    APE_INLINE int * GetDataY() const { return m_spDataY; }
    APE_INLINE CUnBitArrayBase * GetUnBitArrray() const { return m_spUnBitArray; }

    CSmartPtr<int> m_spTempData;
    CSmartPtr<int> m_spDataX;
    CSmartPtr<int> m_spDataY;

    CSmartPtr<CAntiPredictor> m_spAntiPredictorX;
    CSmartPtr<CAntiPredictor> m_spAntiPredictorY;

    CSmartPtr<CUnBitArrayBase> m_spUnBitArray;
    BIT_ARRAY_STATE m_BitArrayStateX;
    BIT_ARRAY_STATE m_BitArrayStateY;

    IAPEDecompress * m_pAPEDecompress;

    int m_nBlocksProcessed;
};

}
