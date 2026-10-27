#pragma once

#include "UnBitArrayBase.h"

namespace APE
{

class IAPEDecompress;
const uint32 Powers_of_Two[32] = { 1,2,4,8,16,32,64,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648U };

/**************************************************************************************************
CUnBitArrayOld
// decodes 0000 up to and including 3890
**************************************************************************************************/
class CUnBitArrayOld : public CUnBitArrayBase
{
public:
    // construction/destruction
    CUnBitArrayOld(IAPEDecompress * pAPEDecompress, intn nVersion, int64 nFurthestReadByte);
    ~CUnBitArrayOld() APE_OVERRIDE;

    // functions
    void GenerateArray(int * pOutputArray, int nElements, intn nBytesRequired = -1) APE_OVERRIDE;
    uint32 DecodeValue(DECODE_VALUE_METHOD DecodeMethod, int nParam1 = 0) APE_OVERRIDE;

private:
    // helpers
    void GenerateArrayOld(int * pOutputArray, uint32 nNumberOfElements, int nMinimumBitArrayBytes);
    void GenerateArrayRice(int * pOutputArray, uint32 nNumberOfElements);
    uint32 DecodeValueRiceUnsigned(uint32 kl);

    // data
    uint32 m_nK;
    uint32 m_nKSum;
    uint32 m_nRefillBitThreshold;

    // functions
    inline int DecodeValueNew(bool bCapOverflow);
    uint32 GetBitsRemaining() const;
    APE_INLINE uint32 Get_K(uint32 x)
    {
        if (x == 0)
            return 0;

        uint32 k = 0;
        while (x >= Powers_of_Two[++k]) { }
        return k;
    }
};

/**************************************************************************************************
CUnBitArray3891To3989
**************************************************************************************************/
class CUnBitArray3891To3989 : public CUnBitArrayBase
{
public:
    // construction/destruction
    CUnBitArray3891To3989(APE::IAPEIO * pIO, intn nVersion, int64 nFurthestReadByte);
    ~CUnBitArray3891To3989() APE_OVERRIDE;

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
    uint32 RangeDecodeFast(int nShift);
    uint32 RangeDecodeFastWithUpdate(int nShift);
    void GenerateArrayRange(int * pOutputArray, int nElements);
};

}
