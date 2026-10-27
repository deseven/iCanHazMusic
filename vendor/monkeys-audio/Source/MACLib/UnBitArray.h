#pragma once

#include "UnBitArrayBase.h"

namespace APE
{

class IAPEDecompress;

/**************************************************************************************************
CUnBitArray
**************************************************************************************************/
class CUnBitArray : public CUnBitArrayBase
{
public:
    // construction/destruction
    CUnBitArray(APE::IAPEIO * pIO, intn nVersion, int64 nFurthestReadByte);
    ~CUnBitArray() APE_OVERRIDE;

    void GenerateArray(int * pOutputArray, int nElements, intn nBytesRequired) APE_OVERRIDE;
    int64 DecodeValueRange(UNBIT_ARRAY_STATE & BitArrayState) APE_OVERRIDE;
    void FlushState(UNBIT_ARRAY_STATE & BitArrayState) APE_OVERRIDE;
    void FlushBitArray() APE_OVERRIDE;
    void Finalize() APE_OVERRIDE;

private:
    // data
    CSmartPtr<RangeOverflowTable> m_spRangeTable;
    RANGE_CODER_STRUCT_DECOMPRESS m_RangeCoderInfo;

    // functions
    uint32 DecodeOverflow(uint32 & nPivotValue);
    uint32 RangeDecodeFast(int nShift);
    uint32 RangeDecodeFastWithUpdate(int nShift);
    void GenerateArrayRange(int * pOutputArray, int nElements);
};

}
