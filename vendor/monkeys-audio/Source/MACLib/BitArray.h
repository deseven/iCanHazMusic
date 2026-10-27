#pragma once

#include "IAPEIO.h"

namespace APE
{

/**************************************************************************************************
Declares
**************************************************************************************************/

//#define BUILD_RANGE_TABLE

struct RANGE_CODER_STRUCT_COMPRESS
{
    unsigned int low;         // low end of interval
    unsigned int range;       // length of interval
    unsigned int help;        // bytes_to_follow resp. intermediate value
    unsigned char buffer;     // buffer for input / output
    unsigned char padding[3]; // buffer alignment
};

struct BIT_ARRAY_STATE
{
    uint32 nKSum;
};

class CBitArray
{
public:
    // construction / destruction
    CBitArray(uint32 nInitialBytes);
    virtual ~CBitArray();

    // encoding
    int EncodeUnsignedLong(unsigned int n);
    int EncodeValue(int64 nEncode, BIT_ARRAY_STATE & BitArrayState);

    // access
    unsigned char * GetBitArray() const { return reinterpret_cast<unsigned char *>(m_paryBitArray); }
    uint32 GetBitArrayBytes() const { return m_nCurrentBitIndex / 8; }

    // other functions
    void Finalize();
    void AdvanceToByteBoundary();
    void FlushState(BIT_ARRAY_STATE & BitArrayState);
    void FlushBitArray();
    void ResetBitArray();

private:
    // data members
    uint32 * m_paryBitArray;
    uint32 m_nBitArrayBytes;
    uint32 m_nRefillThreshold;
    uint32 m_nCurrentBitIndex;
    RANGE_CODER_STRUCT_COMPRESS m_RangeCoderInfo;

    // increase bit array size
    int EnlargeBitArray();

#ifdef BUILD_RANGE_TABLE
    void OutputRangeTable();
#endif
};

}
