/**************************************************************************************************
Includes
**************************************************************************************************/
#include "All.h"
#include "BitArray.h"
#include "GlobalFunctions.h"

namespace APE
{

/**************************************************************************************************
Declares
**************************************************************************************************/
#define APE_BITARRAY_MAX_ELEMENT_BITS        128
#define APE_BITARRAY_SAFE_ZONE_BITS          32

#define APE_BITARRAY_CODE_BITS 32
#define APE_BITARRAY_TOP_VALUE (static_cast<unsigned int>(1) << (APE_BITARRAY_CODE_BITS - 1))
#define APE_BITARRAY_SHIFT_BITS (APE_BITARRAY_CODE_BITS - 9)
#define APE_BITARRAY_BOTTOM_VALUE (APE_BITARRAY_TOP_VALUE >> 8)

#define APE_BITARRAY_OVERFLOW_SIGNAL 1
#define APE_BITARRAY_OVERFLOW_PIVOT_VALUE 32768

/**************************************************************************************************
Lookup tables
**************************************************************************************************/
#define APE_BITARRAY_MODEL_ELEMENTS                  64
#define APE_BITARRAY_RANGE_OVERFLOW_SHIFT            16

const uint32 RANGE_TOTAL[64] = {0,19578,36160,48417,56323,60899,63265,64435,64971,65232,65351,65416,65447,65466,65476,65482,65485,65488,65490,65491,65492,65493,65494,65495,65496,65497,65498,65499,65500,65501,65502,65503,65504,65505,65506,65507,65508,65509,65510,65511,65512,65513,65514,65515,65516,65517,65518,65519,65520,65521,65522,65523,65524,65525,65526,65527,65528,65529,65530,65531,65532,65533,65534,65535,};
const uint32 RANGE_WIDTH[64] = {19578,16582,12257,7906,4576,2366,1170,536,261,119,65,31,19,10,6,3,3,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,};

#ifdef BUILD_RANGE_TABLE
    int g_aryOverflows[256] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    int g_nTotalOverflow = 0;
#endif

/**************************************************************************************************
Constructor
**************************************************************************************************/
CBitArray::CBitArray(uint32 nInitialBytes)
{
    // ensure initial size is a multiple of 4
    nInitialBytes = nInitialBytes / 4 * 4;

    // allocate bit array
    m_paryBitArray = static_cast<uint32 *>(calloc(nInitialBytes, 1));
    m_nBitArrayBytes = nInitialBytes;
    m_nRefillThreshold = m_nBitArrayBytes * 8 - APE_BITARRAY_MAX_ELEMENT_BITS - APE_BITARRAY_SAFE_ZONE_BITS;

    // empty the range code information
    APE_CLEAR(m_RangeCoderInfo);

    // initialize other variables
    m_nCurrentBitIndex = 0;
}

/**************************************************************************************************
Destructor
**************************************************************************************************/
CBitArray::~CBitArray()
{
#ifdef BUILD_RANGE_TABLE
    OutputRangeTable();
#endif

    // free bit array
    free(m_paryBitArray);
}

/**************************************************************************************************
Increase the bit array size
**************************************************************************************************/
int CBitArray::EnlargeBitArray()
{
    // find new bit array size (increase by 20%)
    uint32 nNewBytes = m_nBitArrayBytes / 10 * 12;

    // ensure new size is a multiple of 4
    nNewBytes = nNewBytes / 4 * 4;

    // re-allocate bit array
    uint32 * pNew = static_cast<uint32 *>(realloc(m_paryBitArray, nNewBytes));
    if (pNew == APE_NULL)
        return APE_ERROR_INSUFFICIENT_MEMORY;
    m_paryBitArray = pNew;

    // zero new elements
    memset(m_paryBitArray + m_nBitArrayBytes / 4, 0, static_cast<size_t>(nNewBytes - m_nBitArrayBytes));

    m_nBitArrayBytes = nNewBytes;
    m_nRefillThreshold = m_nBitArrayBytes * 8 - APE_BITARRAY_MAX_ELEMENT_BITS - APE_BITARRAY_SAFE_ZONE_BITS;

    // return a success
    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Reset the bit array by zeroing it
**************************************************************************************************/
void CBitArray::ResetBitArray()
{
    // reset the bit pointer and zero the array
    m_nCurrentBitIndex = 0;
    memset(m_paryBitArray, 0, m_nBitArrayBytes);
}

/**************************************************************************************************
Range coding macros -- ugly, but outperform inline's (every cycle counts here)
**************************************************************************************************/
#if APE_BYTE_ORDER == APE_LITTLE_ENDIAN
    #define APE_PUTC(VALUE) m_paryBitArray[m_nCurrentBitIndex >> 5] |= (static_cast<uint32>(VALUE) & 0xFF) << (24 - (m_nCurrentBitIndex & 31)); m_nCurrentBitIndex += 8;
#else
    #define APE_PUTC(VALUE) m_paryBitArray[m_nCurrentBitIndex >> 5] |= (static_cast<uint32>(VALUE) & 0xFF) << (m_nCurrentBitIndex & 31); m_nCurrentBitIndex += 8;
#endif

#define APE_NORMALIZE_RANGE_CODER                                                                \
    while (m_RangeCoderInfo.range <= APE_BITARRAY_BOTTOM_VALUE)                                  \
    {                                                                                            \
        if (m_RangeCoderInfo.low < (0xFF << APE_BITARRAY_SHIFT_BITS))                            \
        {                                                                                        \
            APE_PUTC(m_RangeCoderInfo.buffer);                                                   \
            for ( ; m_RangeCoderInfo.help; m_RangeCoderInfo.help--) { APE_PUTC(0xFF); }          \
            m_RangeCoderInfo.buffer = static_cast<unsigned char>(m_RangeCoderInfo.low >> static_cast<unsigned int>(APE_BITARRAY_SHIFT_BITS)); \
        }                                                                                        \
        else if (m_RangeCoderInfo.low & APE_BITARRAY_TOP_VALUE)                                  \
        {                                                                                        \
            APE_PUTC(m_RangeCoderInfo.buffer + 1);                                               \
            m_nCurrentBitIndex += (m_RangeCoderInfo.help * 8);                                   \
            m_RangeCoderInfo.help = 0;                                                           \
            m_RangeCoderInfo.buffer = static_cast<unsigned char>(m_RangeCoderInfo.low >> static_cast<unsigned int>(APE_BITARRAY_SHIFT_BITS)); \
        }                                                                                        \
        else                                                                                     \
        {                                                                                        \
            m_RangeCoderInfo.help++;                                                             \
        }                                                                                        \
                                                                                                 \
        m_RangeCoderInfo.low = (m_RangeCoderInfo.low << 8) & (APE_BITARRAY_TOP_VALUE - 1);       \
        m_RangeCoderInfo.range <<= 8;                                                            \
    }

#define APE_ENCODE_FAST(RANGE_WIDTH, RANGE_TOTAL, SHIFT)                                         \
    APE_NORMALIZE_RANGE_CODER                                                                    \
    const unsigned int nTemp = static_cast<unsigned int>(m_RangeCoderInfo.range >> (SHIFT));     \
    m_RangeCoderInfo.range = nTemp * (RANGE_WIDTH);                                              \
    m_RangeCoderInfo.low += nTemp * (RANGE_TOTAL);

#define APE_ENCODE_DIRECT(VALUE, SHIFT)                                                          \
    APE_NORMALIZE_RANGE_CODER                                                                    \
    m_RangeCoderInfo.range = m_RangeCoderInfo.range >> (SHIFT);                                  \
    m_RangeCoderInfo.low += m_RangeCoderInfo.range * (VALUE);

/**************************************************************************************************
Encodes an unsigned int to the bit array (no rice coding)
**************************************************************************************************/
int CBitArray::EncodeUnsignedLong(unsigned int n)
{
    // make sure there is room for the data
    if (m_nCurrentBitIndex > m_nRefillThreshold)
    {
        APE_RETURN_ON_ERROR(EnlargeBitArray())
    }

    // encode the value
    uint32 nBitArrayIndex = m_nCurrentBitIndex >> 5;
    const int nBitIndex = static_cast<int>(m_nCurrentBitIndex & 31);

    if (nBitIndex == 0)
    {
        m_paryBitArray[nBitArrayIndex] = ConvertU32LE(n);
    }
    else
    {
        m_paryBitArray[nBitArrayIndex] |= ConvertU32LE(n) >> nBitIndex;
        m_paryBitArray[nBitArrayIndex + 1] = ConvertU32LE(n) << (32 - nBitIndex);
    }

    m_nCurrentBitIndex += 32;

    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Advance to a byte boundary (for frame alignment)
**************************************************************************************************/
void CBitArray::AdvanceToByteBoundary()
{
    while (m_nCurrentBitIndex % 8)
        m_nCurrentBitIndex++;
}

/**************************************************************************************************
Encode a value
**************************************************************************************************/
int CBitArray::EncodeValue(int64 nEncode, BIT_ARRAY_STATE & BitArrayState)
{
    // make sure there is room for the data
    if (m_nCurrentBitIndex > m_nRefillThreshold)
    {
        APE_RETURN_ON_ERROR(EnlargeBitArray())
    }

    // convert to unsigned
    nEncode = (nEncode > 0) ? nEncode * 2 - 1 : -nEncode * 2;

    // figure the pivot value
    uint32 nPivotValue = APE_MAX(BitArrayState.nKSum / 32, static_cast<uint32>(1));
    const uint64 nOverflow64 = static_cast<uint64>(nEncode / nPivotValue);
    uint32 nOverflow = static_cast<uint32>(nOverflow64);
    if (nOverflow != nOverflow64)
    {
        // overflow happened; increase the pivot value and signal the situation in the bitstream
        nPivotValue = APE_BITARRAY_OVERFLOW_PIVOT_VALUE;
        nOverflow = static_cast<uint32>(nEncode / nPivotValue);

        // signal overflow using a low overflow value that can never occur as a "special" overflow value otherwise
        APE_ENCODE_FAST(RANGE_WIDTH[APE_BITARRAY_MODEL_ELEMENTS - 1], RANGE_TOTAL[APE_BITARRAY_MODEL_ELEMENTS - 1], APE_BITARRAY_RANGE_OVERFLOW_SHIFT)
        APE_ENCODE_DIRECT((APE_BITARRAY_OVERFLOW_SIGNAL >> 16) & 0xFFFF, 16)
        APE_ENCODE_DIRECT(APE_BITARRAY_OVERFLOW_SIGNAL & 0xFFFF, 16)
    }
    const uint32 nBase = static_cast<uint32>(nEncode - (static_cast<int64>(nOverflow) * static_cast<int64>(nPivotValue)));

    // update nKSum
    // this was switched to int64 on the nKsum in build 8.68, but that made 32-bit noise encodes that failed to verify since it wasn't done on the other side
    BitArrayState.nKSum += static_cast<uint32>((nEncode + 1) / 2) - ((BitArrayState.nKSum + 16) >> 5);

    // store the overflow
    if (nOverflow < (APE_BITARRAY_MODEL_ELEMENTS - 1))
    {
        APE_ENCODE_FAST(RANGE_WIDTH[nOverflow], RANGE_TOTAL[nOverflow], APE_BITARRAY_RANGE_OVERFLOW_SHIFT)

        #ifdef BUILD_RANGE_TABLE
            g_aryOverflows[nOverflow]++;
            g_nTotalOverflow++;
        #endif
    }
    else
    {
        // store the "special" overflow (tells that perfect k is encoded next)
        APE_ENCODE_FAST(RANGE_WIDTH[APE_BITARRAY_MODEL_ELEMENTS - 1], RANGE_TOTAL[APE_BITARRAY_MODEL_ELEMENTS - 1], APE_BITARRAY_RANGE_OVERFLOW_SHIFT)

        #ifdef BUILD_RANGE_TABLE
            g_aryOverflows[MODEL_ELEMENTS - 1]++;
            g_nTotalOverflow++;
        #endif

        // code the overflow using straight bits
        APE_ENCODE_DIRECT((nOverflow >> 16) & 0xFFFF, 16)
        APE_ENCODE_DIRECT(nOverflow & 0xFFFF, 16)
    }

    // code the base
    if (nPivotValue >= (1 << 16))
    {
        uint32 nPivotValueBits = 0;
        while ((nPivotValue >> nPivotValueBits) > 0) { nPivotValueBits++; }
        const uint32 nShift = (nPivotValueBits >= 16) ? nPivotValueBits - 16 : 0;
        const uint32 nSplitFactor = static_cast<uint32>(1) << nShift;

        // we know that base is smaller than pivot coming into this
        // however, after we divide both by an integer, they could be the same
        // we account by adding one to the pivot, but this hurts compression
        // by (1 / nSplitFactor) -- therefore we maximize the split factor
        // that gets one added to it

        // encode the pivot as two pieces
        const uint32 nPivotValueA = (nPivotValue / nSplitFactor) + 1;
        const uint32 nPivotValueB = nSplitFactor;

        const uint32 nBaseA = nBase / nSplitFactor;
        const uint32 nBaseB = nBase % nSplitFactor;

        {
            APE_NORMALIZE_RANGE_CODER
            const uint32 nTemp = m_RangeCoderInfo.range / nPivotValueA;
            m_RangeCoderInfo.range = nTemp;
            m_RangeCoderInfo.low += nTemp * nBaseA;
        }

        {
            APE_NORMALIZE_RANGE_CODER
            const uint32 nTemp = m_RangeCoderInfo.range / nPivotValueB;
            m_RangeCoderInfo.range = nTemp;
            m_RangeCoderInfo.low += nTemp * nBaseB;
        }
    }
    else
    {
        APE_NORMALIZE_RANGE_CODER
        const uint32 nTemp = m_RangeCoderInfo.range / nPivotValue;
        m_RangeCoderInfo.range = nTemp;
        m_RangeCoderInfo.low += nTemp * nBase;
    }

    return APE_ERROR_SUCCESS;
}

/**************************************************************************************************
Flush
**************************************************************************************************/
void CBitArray::FlushBitArray()
{
    // advance to a byte boundary (for alignment)
    AdvanceToByteBoundary();

    // the range coder
    m_RangeCoderInfo.low = 0;  // full code range
    m_RangeCoderInfo.range = APE_BITARRAY_TOP_VALUE;
    m_RangeCoderInfo.buffer = 0;
    m_RangeCoderInfo.help = 0;  // no bytes to follow
}

void CBitArray::FlushState(BIT_ARRAY_STATE & BitArrayState)
{
    // ksum
    BitArrayState.nKSum = (1 << 10) * 16;
}

/**************************************************************************************************
Finalize
**************************************************************************************************/
void CBitArray::Finalize()
{
    APE_NORMALIZE_RANGE_CODER

    const unsigned int nTemp = (m_RangeCoderInfo.low >> APE_BITARRAY_SHIFT_BITS) + 1;

    if (nTemp > 0xFF) // we have a carry
    {
        APE_PUTC(m_RangeCoderInfo.buffer + 1)
        for ( ; m_RangeCoderInfo.help; m_RangeCoderInfo.help--)
        {
            APE_PUTC(0)
        }
    }
    else  // no carry
    {
        APE_PUTC(m_RangeCoderInfo.buffer)
        for ( ; m_RangeCoderInfo.help; m_RangeCoderInfo.help--)
        {
            APE_PUTC((static_cast<unsigned char>(0xFF)))
        }
    }

    // we must output these bytes so the decoder can properly work at the end of the stream
    APE_PUTC(nTemp & 0xFF)
    APE_PUTC(0)
    APE_PUTC(0)
    APE_PUTC(0)
}

/**************************************************************************************************
Build a range table (for development / debugging)
**************************************************************************************************/
#ifdef BUILD_RANGE_TABLE
void CBitArray::OutputRangeTable()
{
    int z;

    if (g_nTotalOverflow == 0) return;

    int nTotal = 0;
    int aryWidth[256]; APE_CLEAR(aryWidth);
    for (z = 0; z < MODEL_ELEMENTS; z++)
    {
        aryWidth[z] = static_cast<int>(((float(g_aryOverflows[z]) * float(65536)) + (g_nTotalOverflow / 2)) / float(g_nTotalOverflow));
        if (aryWidth[z] == 0) aryWidth[z] = 1;
        nTotal += aryWidth[z];
    }

    z = 0;
    while (nTotal > 65536)
    {
        if (aryWidth[z] != 1)
        {
            aryWidth[z]--;
            nTotal--;
        }
        z++;
        if (z == MODEL_ELEMENTS) z = 0;
    }

    z = 0;
    while (nTotal < 65536)
    {
        aryWidth[z++]++;
        nTotal++;
        if (z == MODEL_ELEMENTS) z = 0;
    }

    int aryTotal[256]; APE_CLEAR(aryTotal);
    for (z = 0; z < MODEL_ELEMENTS; z++)
    {
        for (int q = 0; q < z; q++)
        {
            aryTotal[z] += aryWidth[q];
        }
    }

    TCHAR buf[1024];
    _stprintf(buf, _T("const uint32 RANGE_TOTAL[%d] = {"), MODEL_ELEMENTS);
    APE_ODS(buf);
    for (z = 0; z < MODEL_ELEMENTS; z++)
    {
        _stprintf(buf, _T("%d,"), aryTotal[z]);
        OutputDebugString(buf);
    }
    APE_ODS(_T("};\n"));

    _stprintf(buf, _T("const uint32 RANGE_WIDTH[%d] = {"), MODEL_ELEMENTS);
    APE_ODS(buf);
    for (z = 0; z < MODEL_ELEMENTS; z++)
    {
        _stprintf(buf, _T("%d,"), aryWidth[z]);
        OutputDebugString(buf);
    }
    APE_ODS(_T("};\n\n"));
}
#endif // #ifdef BUILD_RANGE_TABLE

}
