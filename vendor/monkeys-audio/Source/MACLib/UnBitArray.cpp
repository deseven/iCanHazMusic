#include "All.h"
#include "UnBitArray.h"

namespace APE
{

const uint32 K_SUM_MIN_BOUNDARY[32] = {0,32,64,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648U,0,0,0,0};

/**************************************************************************************************
CUnBitArray
**************************************************************************************************/
CUnBitArray::CUnBitArray(IAPEIO * pIO, intn nVersion, int64 nFurthestReadByte) :
    CUnBitArrayBase(nFurthestReadByte)
{
    // this bit array should only be used on modern files
    ASSERT(nVersion >= 3990);

    // initialize
    APE_CLEAR(m_RangeCoderInfo);
    CreateHelper(pIO, 16384, nVersion);

    // create the range table for the version we're decoding (no need to create both)
    m_spRangeTable.Assign(new RangeOverflowTable(RANGE_TOTAL_2));
}

CUnBitArray::~CUnBitArray()
{
}

void CUnBitArray::GenerateArray(int * pOutputArray, int nElements, intn)
{
    GenerateArrayRange(pOutputArray, nElements);
}

uint32 CUnBitArray::RangeDecodeFast(int nShift)
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

uint32 CUnBitArray::RangeDecodeFastWithUpdate(int nShift)
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

uint32 CUnBitArray::DecodeOverflow(uint32 & nPivotValue)
{
    // decode
    const uint32 nRangeTotal = RangeDecodeFast(APE_BITARRAY_RANGE_OVERFLOW_SHIFT);
    if (nRangeTotal >= 65536)
        throw(static_cast<intn>(APE_ERROR_INVALID_INPUT_FILE));

    // lookup the symbol from lookup table
    uint32 nOverflow = m_spRangeTable->Get(nRangeTotal);

    // update
    m_RangeCoderInfo.low -= m_RangeCoderInfo.range * RANGE_TOTAL_2[nOverflow];
    m_RangeCoderInfo.range = m_RangeCoderInfo.range * RANGE_WIDTH_2[nOverflow];

    // get the working k
    if (nOverflow == (APE_BITARRAY_MODEL_ELEMENTS - 1))
    {
        nOverflow = RangeDecodeFastWithUpdate(16);
        nOverflow <<= 16;
        nOverflow |= RangeDecodeFastWithUpdate(16);

        // detect overflow signaling here, adjust the pivot value and try again
        if (nOverflow == APE_BITARRAY_OVERFLOW_SIGNAL)
        {
            nPivotValue = APE_BITARRAY_OVERFLOW_PIVOT_VALUE;

            return DecodeOverflow(nPivotValue);
        }
    }

    return nOverflow;
}

int64 CUnBitArray::DecodeValueRange(UNBIT_ARRAY_STATE & BitArrayState)
{
    int64 nValue = 0;

    // figure the pivot value
    uint32 nPivotValue = APE_MAX(BitArrayState.nKSum / 32, static_cast<uint32>(1));

    // get the overflow
    const uint32 nOverflow = DecodeOverflow(nPivotValue);

    // get the value
    uint32 nBase = 0;
    {
        if (nPivotValue >= (1 << 16))
        {
            uint32 nPivotValueBits = 0;
            while ((nPivotValue >> nPivotValueBits) > 0) { nPivotValueBits++; }

            const uint32 nShift = (nPivotValueBits >= 16) ? nPivotValueBits - 16 : 0;
            const uint32 nSplitFactor = static_cast<uint32>(1) << nShift;

            const uint32 nPivotValueA = (nPivotValue / nSplitFactor) + 1;
            const uint32 nPivotValueB = nSplitFactor;

            while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)
            {
                m_RangeCoderInfo.buffer = (m_RangeCoderInfo.buffer << 8) | DecodeByte();
                m_RangeCoderInfo.low = (m_RangeCoderInfo.low << 8) | ((m_RangeCoderInfo.buffer >> 1) & 0xFF);
                m_RangeCoderInfo.range <<= 8;
            }
            m_RangeCoderInfo.range /= nPivotValueA;
            const uint32 nBaseA = m_RangeCoderInfo.low / m_RangeCoderInfo.range;
            m_RangeCoderInfo.low = m_RangeCoderInfo.low % m_RangeCoderInfo.range;

            while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)
            {
                m_RangeCoderInfo.buffer = (m_RangeCoderInfo.buffer << 8) | DecodeByte();
                m_RangeCoderInfo.low = (m_RangeCoderInfo.low << 8) | ((m_RangeCoderInfo.buffer >> 1) & 0xFF);
                m_RangeCoderInfo.range <<= 8;
            }
            m_RangeCoderInfo.range /= nPivotValueB;
            const uint32 nBaseB = m_RangeCoderInfo.low / m_RangeCoderInfo.range;
            m_RangeCoderInfo.low = m_RangeCoderInfo.low % m_RangeCoderInfo.range;

            nBase = nBaseA * nSplitFactor + nBaseB;
        }
        else
        {
            while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)
            {
                m_RangeCoderInfo.buffer = (m_RangeCoderInfo.buffer << 8) | DecodeByte();
                m_RangeCoderInfo.low = (m_RangeCoderInfo.low << 8) | ((m_RangeCoderInfo.buffer >> 1) & 0xFF);
                m_RangeCoderInfo.range <<= 8;

                // check for end of life!
                if (m_RangeCoderInfo.range == 0)
                    return 0;
            }

            // decode
            m_RangeCoderInfo.range /= nPivotValue;
            const uint32 nBaseLower = m_RangeCoderInfo.low / m_RangeCoderInfo.range;
            m_RangeCoderInfo.low = m_RangeCoderInfo.low % m_RangeCoderInfo.range;

            nBase = nBaseLower;
        }
    }

    // build the value
    nValue = static_cast<int64>(nBase) + (static_cast<int64>(nOverflow) * nPivotValue);

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

void CUnBitArray::FlushState(UNBIT_ARRAY_STATE & BitArrayState)
{
    BitArrayState.k = 10;
    BitArrayState.nKSum = static_cast<uint32>((1 << BitArrayState.k) * 16);
}

void CUnBitArray::FlushBitArray()
{
    AdvanceToByteBoundary();
    DecodeValueXBits(8); // ignore the first byte... (slows compression too much to not output this dummy byte)
    m_RangeCoderInfo.buffer = DecodeValueXBits(8);
    m_RangeCoderInfo.low = m_RangeCoderInfo.buffer >> (8 - APE_BITARRAY_EXTRA_BITS);
    m_RangeCoderInfo.range = static_cast<unsigned int>(1 << APE_BITARRAY_EXTRA_BITS);
}

void CUnBitArray::Finalize()
{
    // normalize
    while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)
    {
        m_nCurrentBitIndex += 8;
        m_RangeCoderInfo.range <<= 8;
        if (m_RangeCoderInfo.range == 0)
            return; // end of life!
    }
}

void CUnBitArray::GenerateArrayRange(int * pOutputArray, int nElements)
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
