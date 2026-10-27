#include "All.h"
#ifdef APE_BACKWARDS_COMPATIBILITY

#include "APEInfo.h"
#include "UnBitArrayOld.h"

namespace APE
{

const uint32 K_SUM_MIN_BOUNDARY_OLD[32] = {0,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648U,0,0,0,0,0,0};
const uint32 K_SUM_MAX_BOUNDARY_OLD[32] = {128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648U,0,0,0,0,0,0,0};
const uint32 Powers_of_Two_Reversed[32] = {2147483648U,1073741824,536870912,268435456,134217728,67108864,33554432,16777216,8388608,4194304,2097152,1048576,524288,262144,131072,65536,32768,16384,8192,4096,2048,1024,512,256,128,64,32,16,8,4,2,1};
const uint32 Powers_of_Two_Minus_One_Reversed[33] = {4294967295U,2147483647,1073741823,536870911,268435455,134217727,67108863,33554431,16777215,8388607,4194303,2097151,1048575,524287,262143,131071,65535,32767,16383,8191,4095,2047,1023,511,255,127,63,31,15,7,3,1,0};

const uint32 K_SUM_MIN_BOUNDARY[32] = {0,32,64,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648U,0,0,0,0};
const uint32 K_SUM_MAX_BOUNDARY[32] = {32,64,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648U,0,0,0,0,0};

/**************************************************************************************************
CUnBitArrayOld
**************************************************************************************************/
CUnBitArrayOld::CUnBitArrayOld(IAPEDecompress * pAPEDecompress, intn nVersion, int64 nFurthestReadByte) :
    CUnBitArrayBase(nFurthestReadByte)
{
    // initialize (to avoid warnings)
    m_nKSum = 0;
    m_nK = 0;

    // bit array size
    intn nBitArrayBytes = 262144;

    // calculate the bytes
    if (nVersion <= 3880)
    {
        const intn nMaxFrameBytes = (static_cast<intn>(pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCKS_PER_FRAME)) * 50) / 8;
        nBitArrayBytes = 65536;
        while (nBitArrayBytes < nMaxFrameBytes)
        {
            nBitArrayBytes <<= 1;
        }

        nBitArrayBytes = APE_MAX<intn>(nBitArrayBytes, 262144);
    }
    else if (nVersion <= 3890)
    {
        nBitArrayBytes = 65536;
    }
    else
    {
        // error
    }

    CreateHelper(pAPEDecompress->GetIO(), nBitArrayBytes, nVersion);

    // set the refill threshold
    if (m_nVersion <= 3880)
        m_nRefillBitThreshold = (m_nBits - (16384 * 8));
    else
        m_nRefillBitThreshold = (m_nBits - 512);
}

CUnBitArrayOld::~CUnBitArrayOld()
{
}

////////////////////////////////////////////////////////////////////////////////////
// Gets the number of m_nBits of data left in the m_nCurrentBitIndex array
////////////////////////////////////////////////////////////////////////////////////
uint32 CUnBitArrayOld::GetBitsRemaining() const
{
    return (m_nElements * 32 - m_nCurrentBitIndex);
}

////////////////////////////////////////////////////////////////////////////////////
// Gets a rice value from the array
////////////////////////////////////////////////////////////////////////////////////
uint32 CUnBitArrayOld::DecodeValueRiceUnsigned(uint32 k)
{
    // variable declares
    uint32 v;

    // plug through the string of 0's (the overflow)
    const uint32 BitInitial = m_nCurrentBitIndex;
    while (!(m_spBitArray[m_nCurrentBitIndex >> 5] & Powers_of_Two_Reversed[m_nCurrentBitIndex & 31]))
    {
        m_nCurrentBitIndex++;
        if (m_nCurrentBitIndex >= m_nBits)
            throw(static_cast<intn>(APE_ERROR_INVALID_INPUT_FILE));
    }
    m_nCurrentBitIndex++;

    // if k = 0, your done
    if (k == 0)
        return (m_nCurrentBitIndex - BitInitial - 1);

    // put the overflow value into v
    v = (m_nCurrentBitIndex - BitInitial - 1) << k;

    return v | DecodeValueXBits(k);
}

////////////////////////////////////////////////////////////////////////////////////
// Get the optimal k for a given value
////////////////////////////////////////////////////////////////////////////////////
uint32 CUnBitArrayOld::DecodeValue(DECODE_VALUE_METHOD DecodeMethod, int nParam1)
{
    switch (DecodeMethod)
    {
    case DECODE_VALUE_METHOD_UNSIGNED_INT:
        return DecodeValueXBits(32);
    case DECODE_VALUE_METHOD_UNSIGNED_RICE:
        return DecodeValueRiceUnsigned(static_cast<uint32>(nParam1));
    case DECODE_VALUE_METHOD_X_BITS:
        return DecodeValueXBits(static_cast<uint32>(nParam1));
    }

    return 0;
}

////////////////////////////////////////////////////////////////////////////////////
// Generates an array from the m_nCurrentBitIndexarray
////////////////////////////////////////////////////////////////////////////////////
void CUnBitArrayOld::GenerateArrayOld(int * pOutputArray, uint32 nNumberOfElements, int nMinimumBitArrayBytes)
{
    // variable declarations
    uint32 K_Sum;
    uint32 q;
    uint32 kmin, kmax;
    uint32 k;
    uint32 Max;
    int *p1, *p2;

    // fill bit array if necessary
    // could use seek information to determine what the max was...
    uint32 Max_Bits_Needed = nNumberOfElements * 50;

    if (nMinimumBitArrayBytes > 0)
    {
        // this is actually probably double what is really needed
        // we can only calculate the space needed for both arrays in multichannel
        Max_Bits_Needed = static_cast<uint32>((nMinimumBitArrayBytes + 4) * 8);
    }

    if (Max_Bits_Needed > GetBitsRemaining())
        FillBitArray();

    // decode the first 5 elements (all k = 10)
    Max = (nNumberOfElements < 5) ? nNumberOfElements : 5;
    for (q = 0; q < Max; q++)
    {
        pOutputArray[q] = static_cast<int>(DecodeValueRiceUnsigned(10));
    }

    // quit if that was all
    if (nNumberOfElements <= 5)
    {
        for (p2 = &pOutputArray[0]; p2 < &pOutputArray[nNumberOfElements]; p2++)
            *p2 = (*p2 & 1) ? (*p2 >> 1) + 1 : -(*p2 >> 1);
        return;
    }

    // update k and K_Sum
    K_Sum = static_cast<uint32>(pOutputArray[0] + pOutputArray[1] + pOutputArray[2] + pOutputArray[3] + pOutputArray[4]);
    k = Get_K(K_Sum / 10);

    // work through the rest of the elements before the primary loop
    Max = (nNumberOfElements < 64) ? nNumberOfElements : 64;
    for (q = 5; q < Max; q++)
    {
        pOutputArray[q] = static_cast<int>(DecodeValueRiceUnsigned(k));
        K_Sum += static_cast<uint32>(pOutputArray[q]); // we established it was unsigned above
        k = Get_K(K_Sum / (q  + 1) / 2);
    }

    // quit if that was all
    if (nNumberOfElements <= 64)
    {
        for (p2 = &pOutputArray[0]; p2 < &pOutputArray[nNumberOfElements]; p2++)
            *p2 = (*p2 & 1) ? (*p2 >> 1) + 1 : -(*p2 >> 1);
        return;
    }

    // set all of the variables up for the primary loop
    uint32 v, Bit_Array_Index;
    k = Get_K(K_Sum >> 7);
    kmin = K_SUM_MIN_BOUNDARY_OLD[k];
    kmax = K_SUM_MAX_BOUNDARY_OLD[k];

    // the primary loop
    for (p1 = &pOutputArray[64], p2 = &pOutputArray[0]; p1 < &pOutputArray[nNumberOfElements]; p1++, p2++)
    {
        // plug through the string of 0's (the overflow)
        const uint32 nBitInitial = m_nCurrentBitIndex;
        while (!(m_spBitArray[m_nCurrentBitIndex >> 5] & Powers_of_Two_Reversed[m_nCurrentBitIndex & 31]))
        {
            m_nCurrentBitIndex++;
            if (m_nCurrentBitIndex >= m_nBits)
                throw(static_cast<intn>(APE_ERROR_INVALID_INPUT_FILE));
        }
        m_nCurrentBitIndex++;

        // if k = 0, your done
        if (k == 0)
        {
            v = (m_nCurrentBitIndex - nBitInitial - 1);
        }
        else
        {
            // put the overflow value into v
            v = (m_nCurrentBitIndex - nBitInitial - 1) << k;

            // store the bit information and incement the bit pointer by 'k'
            Bit_Array_Index = m_nCurrentBitIndex >> 5;
            const unsigned int Bit_Index = m_nCurrentBitIndex & 31;
            m_nCurrentBitIndex += k;

            // figure the extra bits on the left and the left value
            const int Left_Extra_Bits = static_cast<int>((32 - k) - Bit_Index);
            const unsigned int Left_Value = m_spBitArray[Bit_Array_Index] & Powers_of_Two_Minus_One_Reversed[Bit_Index];

            if (Left_Extra_Bits >= 0)
                v |= (Left_Value >> Left_Extra_Bits);
            else
                v |= (Left_Value << -Left_Extra_Bits) | (m_spBitArray[Bit_Array_Index + 1] >> (32 + Left_Extra_Bits));
        }

        *p1 = static_cast<int>(v);
        K_Sum += static_cast<uint32>(*p1 - *p2);

        // convert *p2 to unsigned
        *p2 = (*p2 % 2) ? (*p2 >> 1) + 1 : -(*p2 >> 1);

        // adjust k if necessary
        if ((K_Sum < kmin) || (K_Sum >= kmax))
        {
            if (K_Sum < kmin)
            {
                do 
                {
                    k--;
                } while (K_Sum < K_SUM_MIN_BOUNDARY_OLD[k]);
            }
            else
            {
                while (K_SUM_MAX_BOUNDARY_OLD[k + 1])
                {
                    k++;
                    if (K_Sum < K_SUM_MAX_BOUNDARY_OLD[k]) 
                        break;
                }
            }                

            kmax = K_SUM_MAX_BOUNDARY_OLD[k];
            kmin = K_SUM_MIN_BOUNDARY_OLD[k];
        }
    }

    for (; p2 < &pOutputArray[nNumberOfElements]; p2++)
        *p2 = (*p2 & 1) ? (*p2 >> 1) + 1 : -(*p2 >> 1);
}

void CUnBitArrayOld::GenerateArray(int * pOutputArray, int nElements, intn nBytesRequired)
{
    if (m_nVersion < 3860)
    {
        GenerateArrayOld(pOutputArray, static_cast<uint32>(nElements), static_cast<int>(nBytesRequired));
    }
    else if (m_nVersion <= 3890)
    {
        GenerateArrayRice(pOutputArray, static_cast<uint32>(nElements));
    }
    else
    {
        // error
    }
}

void CUnBitArrayOld::GenerateArrayRice(int * pOutputArray, uint32 nNumberOfElements)
{
    /////////////////////////////////////////////////////////////////////////////
    // decode the bit array
    /////////////////////////////////////////////////////////////////////////////

    m_nK = 10;
    m_nKSum = 1024 * 16;

    if (m_nVersion <= 3880)
    {
        // the primary loop
        for (int * p1 = &pOutputArray[0]; p1 < &pOutputArray[nNumberOfElements]; p1++)
        {
            *p1 = DecodeValueNew(false);
        }
    }
    else
    {
        // the primary loop
        for (int * p1 = &pOutputArray[0]; p1 < &pOutputArray[nNumberOfElements]; p1++)
        {
            *p1 = DecodeValueNew(true);
        }
    }
}

inline int CUnBitArrayOld::DecodeValueNew(bool bCapOverflow)
{
    // make sure there is room for the data
    // this is a little slower than ensuring a huge block to start with, but it's safer
    if (m_nCurrentBitIndex > m_nRefillBitThreshold)
    {
        FillBitArray();
    }

    unsigned int v;

    // plug through the string of 0's (the overflow)
    const uint32 nBitInitial = m_nCurrentBitIndex;
    while (!(m_spBitArray[m_nCurrentBitIndex >> 5] & Powers_of_Two_Reversed[m_nCurrentBitIndex & 31])) {
        m_nCurrentBitIndex++;
    }
    m_nCurrentBitIndex++;

    int nOverflow = static_cast<int>(m_nCurrentBitIndex - nBitInitial - 1);

    if (bCapOverflow)
    {
        while (nOverflow >= 16)
        {
            m_nK += 4;
            nOverflow -= 16;
        }
    }

    // if k = 0, your done
    if (m_nK != 0)
    {
        // put the overflow value into v
        v = static_cast<unsigned int>(nOverflow << m_nK);

        // store the bit information and incement the bit pointer by 'k'
        const unsigned int Bit_Array_Index = m_nCurrentBitIndex >> 5;
        const unsigned int Bit_Index = m_nCurrentBitIndex & 31;
        m_nCurrentBitIndex += m_nK;

        // figure the extra bits on the left and the left value
        const int nLeftExtraBits = static_cast<int>((32 - m_nK) - Bit_Index);
        const unsigned int Left_Value = m_spBitArray[Bit_Array_Index] & Powers_of_Two_Minus_One_Reversed[Bit_Index];

        if (nLeftExtraBits >= 0)
        {
            v |= (Left_Value >> nLeftExtraBits);
        }
        else
        {
            v |= (Left_Value << -nLeftExtraBits) | (m_spBitArray[Bit_Array_Index + 1] >> (32 + nLeftExtraBits));
        }
    }
    else
    {
        v = static_cast<unsigned int>(nOverflow);
    }

    // update K_Sum
    m_nKSum += v - ((m_nKSum + 8) >> 4);

    // clip k
    if (m_nK > 31)
        m_nK = 31;

    // update k
    if (m_nKSum < K_SUM_MIN_BOUNDARY[m_nK])
        m_nK--;
    else if (K_SUM_MAX_BOUNDARY[m_nK] && m_nKSum >= K_SUM_MAX_BOUNDARY[m_nK])
        m_nK++;

    // convert to unsigned and save
    return (v & 1) ? static_cast<int>(v >> 1) + 1 : -(static_cast<int>(v >> 1));
}

/**************************************************************************************************
CUnBitArray3891To3989
**************************************************************************************************/
CUnBitArray3891To3989::CUnBitArray3891To3989(IAPEIO * pIO, intn nVersion, int64 nFurthestReadByte) :
    CUnBitArrayBase(nFurthestReadByte)
{
    APE_CLEAR(m_RangeCoderInfo);
    CreateHelper(pIO, 16384, nVersion);

    // create the range table
    m_spRangeTable.Assign(new RangeOverflowTable(RANGE_TOTAL_1));
}

CUnBitArray3891To3989::~CUnBitArray3891To3989()
{
}

void CUnBitArray3891To3989::GenerateArray(int * pOutputArray, int nElements, intn)
{
    GenerateArrayRange(pOutputArray, nElements);
}

uint32 CUnBitArray3891To3989::RangeDecodeFast(int nShift)
{
    while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)
    {
        m_RangeCoderInfo.buffer = (m_RangeCoderInfo.buffer << 8) | DecodeByte();
        m_RangeCoderInfo.low = (m_RangeCoderInfo.low << 8) | ((m_RangeCoderInfo.buffer >> 1) & 0xFF);
        m_RangeCoderInfo.range <<= 8;

        // check for end of life
        if (m_RangeCoderInfo.range == 0)
            return 0;
    }

    // decode
    m_RangeCoderInfo.range >>= nShift;

    return m_RangeCoderInfo.low / m_RangeCoderInfo.range;
}

uint32 CUnBitArray3891To3989::RangeDecodeFastWithUpdate(int nShift)
{
    // update range
    while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)
    {
        // if the decoder's range falls to zero, it means the input bitstream is corrupt
        if (m_RangeCoderInfo.range == 0)
        {
            ASSERT(false);
            throw(static_cast<intn>(APE_ERROR_UNDEFINED));
        }

        // read byte and update range
        m_RangeCoderInfo.buffer = (m_RangeCoderInfo.buffer << 8) | DecodeByte();
        m_RangeCoderInfo.low = (m_RangeCoderInfo.low << 8) | ((m_RangeCoderInfo.buffer >> 1) & 0xFF);
        m_RangeCoderInfo.range <<= 8;
    }

    // decode
    m_RangeCoderInfo.range >>= nShift;

    // check for an invalid range value
    if (m_RangeCoderInfo.range == 0)
    {
        ASSERT(false);
        throw(static_cast<intn>(APE_ERROR_UNDEFINED));
    }

    // get the result
    const uint32 nResult = m_RangeCoderInfo.low / m_RangeCoderInfo.range;
    m_RangeCoderInfo.low = m_RangeCoderInfo.low % m_RangeCoderInfo.range;
    return nResult;
}

int64 CUnBitArray3891To3989::DecodeValueRange(UNBIT_ARRAY_STATE & BitArrayState)
{
    int64 nValue = 0;

    // decode
    const uint32 nRangeTotal = RangeDecodeFast(APE_BITARRAY_RANGE_OVERFLOW_SHIFT);
    if (nRangeTotal >= 65536)
        throw(static_cast<intn>(APE_ERROR_INVALID_INPUT_FILE));

    // lookup the symbol from lookup table
    uint32 nOverflow = m_spRangeTable->Get(nRangeTotal);

    // update
    m_RangeCoderInfo.low -= m_RangeCoderInfo.range * RANGE_TOTAL_1[nOverflow];
    m_RangeCoderInfo.range = m_RangeCoderInfo.range * RANGE_WIDTH_1[nOverflow];

    // get the working k
    uint32 nTempK;
    if (nOverflow == (APE_BITARRAY_MODEL_ELEMENTS - 1))
    {
        nTempK = RangeDecodeFastWithUpdate(5);
        nOverflow = 0;
    }
    else
    {
        nTempK = (BitArrayState.k < 1) ? 0 : BitArrayState.k - 1;
    }

    // figure the extra bits on the left and the left value
    if ((nTempK <= 16) || (m_nVersion < 3910))
    {
        nValue = RangeDecodeFastWithUpdate(static_cast<int>(nTempK));
    }
    else
    {
        const uint32 nX1 = RangeDecodeFastWithUpdate(16);
        const uint32 nX2 = RangeDecodeFastWithUpdate(static_cast<int>(nTempK - 16));
        // switched from nValue = nX1 | (nX2 << 16); on 1/30/2024 to avoid a warning (since x2 could overflow when shifted up by 16) (compressed a 24-bit noise file with 3.94 and it still verified)
        nValue = nX1;
        nValue |= (static_cast<int64>(nX2) << 16);
    }

    // build the value and output it
    // this used to be an integer value, but now is int64
    // the overflow shifted by k should still fit in 32-bits, but
    // we'll expand to 64-bits to avoid a warning
    nValue += static_cast<int64>(nOverflow) << nTempK;

    // update nKSum
    BitArrayState.nKSum += static_cast<uint32>(((nValue + 1) / 2)) - ((BitArrayState.nKSum + 16) >> 5);

    // update k
    if (BitArrayState.nKSum < K_SUM_MIN_BOUNDARY[BitArrayState.k])
        BitArrayState.k--;
    else if (K_SUM_MIN_BOUNDARY[BitArrayState.k + 1] && BitArrayState.nKSum >= K_SUM_MIN_BOUNDARY[BitArrayState.k + 1])
        BitArrayState.k++;

    // output the value (converted to signed)
    return (nValue & 1) ? (nValue >> 1) + 1 : -(nValue >> 1);
}

void CUnBitArray3891To3989::FlushState(UNBIT_ARRAY_STATE & BitArrayState)
{
    BitArrayState.k = 10;
    BitArrayState.nKSum = static_cast<uint32>((1 << BitArrayState.k) * 16);
}

void CUnBitArray3891To3989::FlushBitArray()
{
    AdvanceToByteBoundary();
    DecodeValueXBits(8); // ignore the first byte... (slows compression too much to not output this dummy byte)
    m_RangeCoderInfo.buffer = DecodeValueXBits(8);
    m_RangeCoderInfo.low = m_RangeCoderInfo.buffer >> (8 - APE_BITARRAY_EXTRA_BITS);
    m_RangeCoderInfo.range = static_cast<unsigned int>(1 << APE_BITARRAY_EXTRA_BITS);
}

void CUnBitArray3891To3989::Finalize()
{
    // normalize
    while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)
    {
        m_nCurrentBitIndex += 8;
        m_RangeCoderInfo.range <<= 8;
        if (m_RangeCoderInfo.range == 0)
            return; // end of life!
    }

    // used to back-pedal the last two bytes out
    // this should never have been a problem because we've outputted and normalized beforehand
    // but stopped doing it as of 3.96 in case it accounted for rare decompression failures
    if (m_nVersion <= 3950)
        m_nCurrentBitIndex -= 16;
}

void CUnBitArray3891To3989::GenerateArrayRange(int * pOutputArray, int nElements)
{
    UNBIT_ARRAY_STATE BitArrayState;
    FlushState(BitArrayState);
    FlushBitArray();

    for (int z = 0; z < nElements; z++)
    {
        pOutputArray[z] = static_cast<int>(DecodeValueRange(BitArrayState));
    }

    Finalize();
}

}

#endif // #ifdef APE_BACKWARDS_COMPATIBILITY
