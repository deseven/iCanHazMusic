#pragma once

namespace APE
{

class IAPEDecompress;
class IAPEIO;

/**************************************************************************************************
Defines
**************************************************************************************************/
#define APE_BITARRAY_RANGE_OVERFLOW_SHIFT 16

#define APE_BITARRAY_CODE_BITS 32
#define APE_BITARRAY_TOP_VALUE (static_cast<unsigned int> (static_cast<unsigned int>(1) << (APE_BITARRAY_CODE_BITS - 1)))
#define APE_BITARRAY_EXTRA_BITS ((APE_BITARRAY_CODE_BITS - 2) % 8 + 1)
#define APE_BITARRAY_BOTTOM_VALUE static_cast<unsigned int>(APE_BITARRAY_TOP_VALUE >> 8)

#define APE_BITARRAY_OVERFLOW_SIGNAL 1
#define APE_BITARRAY_OVERFLOW_PIVOT_VALUE 32768

#define APE_BITARRAY_MODEL_ELEMENTS 64

const uint32 RANGE_TOTAL_1[65] = { 0,14824,28224,39348,47855,53994,58171,60926,62682,63786,64463,64878,65126,65276,65365,65419,65450,65469,65480,65487,65491,65493,65494,65495,65496,65497,65498,65499,65500,65501,65502,65503,65504,65505,65506,65507,65508,65509,65510,65511,65512,65513,65514,65515,65516,65517,65518,65519,65520,65521,65522,65523,65524,65525,65526,65527,65528,65529,65530,65531,65532,65533,65534,65535,65536 };
const uint32 RANGE_WIDTH_1[64] = { 14824,13400,11124,8507,6139,4177,2755,1756,1104,677,415,248,150,89,54,31,19,11,7,4,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1 };

const uint32 RANGE_TOTAL_2[65] = { 0,19578,36160,48417,56323,60899,63265,64435,64971,65232,65351,65416,65447,65466,65476,65482,65485,65488,65490,65491,65492,65493,65494,65495,65496,65497,65498,65499,65500,65501,65502,65503,65504,65505,65506,65507,65508,65509,65510,65511,65512,65513,65514,65515,65516,65517,65518,65519,65520,65521,65522,65523,65524,65525,65526,65527,65528,65529,65530,65531,65532,65533,65534,65535,65536 };
const uint32 RANGE_WIDTH_2[64] = { 19578,16582,12257,7906,4576,2366,1170,536,261,119,65,31,19,10,6,3,3,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1 };

/**************************************************************************************************
UNBIT_ARRAY_STATE
**************************************************************************************************/
struct UNBIT_ARRAY_STATE
{
    uint32 k;
    uint32 nKSum;
};

/**************************************************************************************************
CUnBitArrayBase
**************************************************************************************************/
class CUnBitArrayBase
{
public:
    // enumeration
    enum DECODE_VALUE_METHOD
    {
        DECODE_VALUE_METHOD_UNSIGNED_INT,
        DECODE_VALUE_METHOD_UNSIGNED_RICE,
        DECODE_VALUE_METHOD_X_BITS
    };

    // construction / destruction
    CUnBitArrayBase(int64 nFurthestReadByte);
    virtual ~CUnBitArrayBase();

    // functions
    virtual int FillBitArray();
    virtual int FillAndResetBitArray(int64 nFileLocation = -1, int64 nNewBitIndex = 0);

    virtual void GenerateArray(int * pOutputArray, int nElements, intn nBytesRequired) = 0;
    virtual uint32 DecodeValue(DECODE_VALUE_METHOD DecodeMethod, int nParam1 = 0);

    virtual void AdvanceToByteBoundary();
    virtual bool EnsureBitsAvailable(uint32 nBits, bool bThrowExceptionOnFailure);

    virtual int64 DecodeValueRange(UNBIT_ARRAY_STATE &) { return 0; }
    virtual void FlushState(UNBIT_ARRAY_STATE &) { }
    virtual void FlushBitArray() { }
    virtual void Finalize() { }

protected:
    // helpers
    virtual int CreateHelper(IAPEIO * pIO, intn nBytes, intn nVersion);
    virtual uint32 DecodeValueXBits(uint32 nBits);

    // helpers (inline)
    inline uint32 DecodeByte()
    {
        if ((m_nCurrentBitIndex + 8) >= (m_nGoodBytes * 8))
            EnsureBitsAvailable(8, true);

        // read byte
        const uint32 nByte = ((m_spBitArray[m_nCurrentBitIndex >> 5] >> (24 - (m_nCurrentBitIndex & 31))) & 0xFF);
        m_nCurrentBitIndex += 8;
        return nByte;
    }

    // data
    uint32 m_nElements;
    uint32 m_nBytes;
    uint32 m_nBits;
    uint32 m_nGoodBytes;

    intn m_nVersion;
    IAPEIO * m_pIO;
    int64 m_nFurthestReadByte;

    CSmartPtr<uint32> m_spBitArray;
    uint32 m_nCurrentBitIndex;
};

/**************************************************************************************************
RangeOverflowTable
**************************************************************************************************/
class RangeOverflowTable
{
public:
    RangeOverflowTable(const uint32* RANGE_TOTAL);
    ~RangeOverflowTable();

    APE_INLINE uint8 Get(uint32 nIndex) const { return m_aryTable[nIndex]; }

private:
    uint8 m_aryTable[65536];
};

/**************************************************************************************************
RANGE_CODER_STRUCT_DECOMPRESS
**************************************************************************************************/
struct RANGE_CODER_STRUCT_DECOMPRESS
{
    unsigned int low;       // low end of interval
    unsigned int range;     // length of interval
    unsigned int buffer;    // buffer for input/output
    unsigned int padding;   // for 64-bit alignment
};

/**************************************************************************************************
CreateUnBitArray
**************************************************************************************************/
CUnBitArrayBase * CreateUnBitArray(IAPEDecompress * pAPEDecompress, IAPEIO * pIO, intn nVersion);

}
