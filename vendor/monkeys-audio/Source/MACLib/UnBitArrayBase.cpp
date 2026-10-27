#include "All.h"
#include "UnBitArrayBase.h"
#include "APEInfo.h"
#include "IAPETag.h"
#include "UnBitArray.h"
#ifdef APE_BACKWARDS_COMPATIBILITY
    #include "Old/UnBitArrayOld.h"
#endif
#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    #include "GlobalFunctions.h"
#endif

namespace APE
{

const uint32 POWERS_OF_TWO_MINUS_ONE[33] = {0,1,3,7,15,31,63,127,255,511,1023,2047,4095,8191,16383,32767,65535,131071,262143,524287,1048575,2097151,4194303,8388607,16777215,33554431,67108863,134217727,268435455,536870911,1073741823,2147483647,4294967295U};

/**************************************************************************************************
CreateUnBitArray
**************************************************************************************************/
#ifdef APE_BACKWARDS_COMPATIBILITY
CUnBitArrayBase * CreateUnBitArray(IAPEDecompress * pAPEDecompress, IAPEIO * pIO, intn nVersion)
{
    // determine the furthest position we should read in the I/O object
    int64 nFurthestReadByte = pIO->GetSize();

    if (nVersion < 3900)
    {
        if (nFurthestReadByte > 0)
        {
            // terminating data
            nFurthestReadByte -= pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES);

            // tag (not worth analyzing the tag since we could be a remote file, etc.)
            // also don't not read the tag if we're working on an APL file
            if (pAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_APL) == 0)
            {
                IAPETag * pAPETag = pAPEDecompress->GetTag();
                if ((pAPETag != APE_NULL) && pAPETag->GetAnalyzed())
                    nFurthestReadByte -= pAPETag->GetTagBytes();
            }
        }

        return dynamic_cast<CUnBitArrayBase *>(new CUnBitArrayOld(pAPEDecompress, nVersion, nFurthestReadByte));
    }
    else if (nVersion < 3990)
    {
        return dynamic_cast<CUnBitArrayBase *>(new CUnBitArray3891To3989(pIO, nVersion, nFurthestReadByte));
    }
    else
    {
        return dynamic_cast<CUnBitArrayBase *>(new CUnBitArray(pIO, nVersion, nFurthestReadByte));
    }
}
#else
CUnBitArrayBase * CreateUnBitArray(IAPEDecompress *, IAPEIO * pIO, intn nVersion)
{
    // determine the furthest position we should read in the I/O object
    int64 nFurthestReadByte = pIO->GetSize();

    // create the appropriate object
    if (nVersion < 3990)
    {
        // we should no longer be trying to decode files this old (this check should be redundant since
        // the main gate keeper should be CreateIAPEDecompressCore(...)
        ASSERT(false);
        return APE_NULL;
    }

    return dynamic_cast<CUnBitArrayBase *>(new CUnBitArray(pIO, nVersion, nFurthestReadByte));
}
#endif

/**************************************************************************************************
RangeOverflowTable
**************************************************************************************************/
RangeOverflowTable::RangeOverflowTable(const uint32 * RANGE_TOTAL)
{
    uint8 nOverflow = 0;
    for (uint32 z = 0; z < 65536; z++)
    {
        if (z >= RANGE_TOTAL[nOverflow + 1])
            nOverflow++;

        m_aryTable[z] = nOverflow;
    }
}

RangeOverflowTable::~RangeOverflowTable()
{
}

/**************************************************************************************************
CUnBitArrayBase
**************************************************************************************************/
CUnBitArrayBase::CUnBitArrayBase(int64 nFurthestReadByte)
{
    m_nElements = 0;
    m_nBytes = 0;
    m_nBits = 0;
    m_nGoodBytes = 0;
    m_nVersion = 0;
    m_pIO = APE_NULL;
    m_nFurthestReadByte = nFurthestReadByte;
    m_nCurrentBitIndex = 0;
}

CUnBitArrayBase::~CUnBitArrayBase()
{
}

void CUnBitArrayBase::AdvanceToByteBoundary()
{
    const uint32 nMod = (m_nCurrentBitIndex % 8);
    if (nMod != 0) { m_nCurrentBitIndex += 8 - nMod; }
}

bool CUnBitArrayBase::EnsureBitsAvailable(uint32 nBits, bool bThrowExceptionOnFailure)
{
    bool bResult = true;

    // get more data if necessary
    if ((m_nCurrentBitIndex + nBits) >= (m_nGoodBytes * 8))
    {
        // fill
        bool bSuccess = (FillBitArray() == APE_ERROR_SUCCESS);

        // if we still don't have enough good bytes, we don't have the bits available
        if (!bSuccess || ((m_nCurrentBitIndex + nBits) >= (m_nGoodBytes * 8)))
        {
            // overread error
            ASSERT(false);

            // throw exception if specified
            if (bThrowExceptionOnFailure)
                throw(static_cast<intn>(APE_ERROR_UNDEFINED));

            // data not available
            bResult = false;
        }
    }

    return bResult;
}

uint32 CUnBitArrayBase::DecodeValueXBits(uint32 nBits)
{
    // get more data if necessary
    EnsureBitsAvailable(nBits, true);

    // variable declares
    const uint32 nLeftBits = 32 - (m_nCurrentBitIndex & 31);
    const uint32 nBitArrayIndex = m_nCurrentBitIndex >> 5;
    m_nCurrentBitIndex += nBits;

    // if their isn't an overflow to the right value, get the value and exit
    if (nLeftBits >= nBits)
        return (m_spBitArray[nBitArrayIndex] & (POWERS_OF_TWO_MINUS_ONE[nLeftBits])) >> (nLeftBits - nBits);

    // must get the "split" value from left and right
    const int nRightBits = static_cast<int>(nBits - nLeftBits);

    const uint32 nLeftValue = ((m_spBitArray[nBitArrayIndex] & POWERS_OF_TWO_MINUS_ONE[nLeftBits]) << nRightBits);
    const uint32 nRightValue = (m_spBitArray[nBitArrayIndex + 1] >> (32 - nRightBits));
    return (nLeftValue | nRightValue);
}

int CUnBitArrayBase::FillAndResetBitArray(int64 nFileLocation, int64 nNewBitIndex)
{
    if (nNewBitIndex < 0) return APE_ERROR_INVALID_INPUT_FILE;

    // seek if necessary
    if (nFileLocation != -1)
    {
        APE_RETURN_ON_ERROR(m_pIO->Seek(nFileLocation, SeekFileBegin))
    }

    // fill
    m_nCurrentBitIndex = m_nBits; // position at the end of the buffer
    const int nResult = FillBitArray();

    // set bit index
    m_nCurrentBitIndex = static_cast<uint32>(nNewBitIndex);

    return nResult;
}

uint32 CUnBitArrayBase::DecodeValue(DECODE_VALUE_METHOD DecodeMethod, int)
{
    if (DecodeMethod == DECODE_VALUE_METHOD_UNSIGNED_INT)
        return DecodeValueXBits(32);

    return 0;
}

int CUnBitArrayBase::FillBitArray()
{
    // get the bit array index
    uint32 nBitArrayIndex = m_nCurrentBitIndex >> 5;

    // move the remaining data to the front
    const int nBytesToMove = static_cast<int>(m_nBytes - (nBitArrayIndex * 4));
    if (nBytesToMove > 0)
        memmove(m_spBitArray, (m_spBitArray + nBitArrayIndex), static_cast<size_t>(nBytesToMove));

    // get the number of bytes to read
    int64 nBytesToRead = static_cast<int64>(nBitArrayIndex) * 4;
    if (m_nFurthestReadByte > 0)
    {
        const int64 nFurthestReadBytes = m_nFurthestReadByte - m_pIO->GetPosition();
        if (nBytesToRead > nFurthestReadBytes)
        {
            nBytesToRead = nFurthestReadBytes;
            if (nBytesToRead < 0)
                nBytesToRead = 0;
        }
    }

    // read the new data
    int64 nBytesRead = 0;
    const int nResult = m_pIO->Read(m_spBitArray + m_nElements - nBitArrayIndex, nBytesToRead, &nBytesRead);

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    SwitchBufferBytes(&m_spBitArray[m_nElements - nBitArrayIndex], 4, nBitArrayIndex);
#endif

    // zero anything at the tail we didn't fill
    m_nGoodBytes = ((m_nElements - nBitArrayIndex) * 4) + static_cast<uint32>(nBytesRead);
    if (m_nGoodBytes < m_nBytes)
        memset(&(reinterpret_cast<unsigned char *>(m_spBitArray.GetPtr()))[m_nGoodBytes], 0, static_cast<size_t>(m_nBytes - m_nGoodBytes));

    // adjust the m_Bit pointer
    m_nCurrentBitIndex = m_nCurrentBitIndex & 31;

    // return
    return (nResult == 0) ? APE_ERROR_SUCCESS : APE_ERROR_IO_READ;
}

int CUnBitArrayBase::CreateHelper(IAPEIO * pIO, intn nBytes, intn nVersion)
{
    // check the parameters
    if ((pIO == APE_NULL) || (nBytes <= 0)) { return APE_ERROR_BAD_PARAMETER; }

    // save the size
    m_nElements = static_cast<uint32>(nBytes / 4);
    m_nBytes = m_nElements * 4;
    m_nBits = m_nBytes * 8;
    m_nGoodBytes = 0;

    // set the variables
    m_pIO = pIO;
    m_nVersion = nVersion;
    m_nCurrentBitIndex = 0;

    // create the bitarray (we allocate and empty a little extra as buffer insurance, although it should never be necessary)
    int64 nAllocateElements = static_cast<int64>(m_nElements) + 64;
    m_spBitArray.AllocateArray(nAllocateElements, true);
    if (m_spBitArray == APE_NULL)
        return APE_ERROR_INSUFFICIENT_MEMORY;

    return APE_ERROR_SUCCESS;
}

}
