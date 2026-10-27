#pragma once

namespace APE
{

/**************************************************************************************************
Definitions
**************************************************************************************************/
class IAPEIO;

/**************************************************************************************************
Read / Write from an IO source and return failure if the number of bytes specified
isn't read or written
**************************************************************************************************/
int ReadSafe(IAPEIO * pIO, void * pBuffer, int64 nBytes);

/**************************************************************************************************
Allocate aligned memory
**************************************************************************************************/
void * AllocateAligned(intn nBytes, intn nAlignment);
void FreeAligned(void * pMemory);

/**************************************************************************************************
String helpers
**************************************************************************************************/
bool StringIsEqual(const str_utfn * pString1, const str_utfn * pString2, bool bCaseSensitive, int nCharacters = -1);

/**************************************************************************************************
Byte order conversion
**************************************************************************************************/
void SwitchBufferBytes(void * pBuffer, int nBytesPerBlock, int nBlocks);

inline uint16 Switch2Bytes(uint16 nValue)
{
    return static_cast<uint16>(((nValue & 0x00FFU) << 8) | ((nValue & 0xFF00U) >> 8));
}

inline uint32 Switch3Bytes(uint32 nValue)
{
    return ((nValue & 0x0000FFU) << 16) | (nValue & 0x00FF00U) | ((nValue & 0xFF0000U) >> 16);
}

inline uint32 Switch4Bytes(uint32 nValue)
{
    return ((nValue & 0x000000FFU) << 24) | ((nValue & 0x0000FF00U) <<  8) |
           ((nValue & 0x00FF0000U) >>  8) | ((nValue & 0xFF000000U) >> 24);
}

inline uint64 Switch8Bytes(uint64 nValue)
{
    return ((nValue & 0x00000000000000FFULL) << 56) | ((nValue & 0x000000000000FF00ULL) << 40) |
           ((nValue & 0x0000000000FF0000ULL) << 24) | ((nValue & 0x00000000FF000000ULL) <<  8) |
           ((nValue & 0x000000FF00000000ULL) >>  8) | ((nValue & 0x0000FF0000000000ULL) >> 24) |
           ((nValue & 0x00FF000000000000ULL) >> 40) | ((nValue & 0xFF00000000000000ULL) >> 56);
}

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    #define ConvertI16BE(val) (val)
    #define ConvertI32BE(val) (val)
    #define ConvertI64BE(val) (val)

    #define ConvertU16BE(val) (val)
    #define ConvertU32BE(val) (val)
    #define ConvertU64BE(val) (val)

    #define ConvertI16LE(val) static_cast<int16>(Switch2Bytes(static_cast<uint16>(val)))
    #define ConvertI32LE(val) static_cast<int32>(Switch4Bytes(static_cast<uint32>(val)))
    #define ConvertI64LE(val) static_cast<int64>(Switch8Bytes(static_cast<uint64>(val)))

    #define ConvertU16LE(val) Switch2Bytes(val)
    #define ConvertU32LE(val) Switch4Bytes(val)
    #define ConvertU64LE(val) Switch8Bytes(val)
#else
    #define ConvertI16BE(val) static_cast<int16>(Switch2Bytes(static_cast<uint16>(val)))
    #define ConvertI32BE(val) static_cast<int32>(Switch4Bytes(static_cast<uint32>(val)))
    #define ConvertI64BE(val) static_cast<int64>(Switch8Bytes(static_cast<uint64>(val)))

    #define ConvertU16BE(val) Switch2Bytes(val)
    #define ConvertU32BE(val) Switch4Bytes(val)
    #define ConvertU64BE(val) Switch8Bytes(val)

    #define ConvertI16LE(val) (val)
    #define ConvertI32LE(val) (val)
    #define ConvertI64LE(val) (val)

    #define ConvertU16LE(val) (val)
    #define ConvertU32LE(val) (val)
    #define ConvertU64LE(val) (val)
#endif

/**************************************************************************************************
Get the number of threads from the specified number (handles automatic)
**************************************************************************************************/
int GetNumberThreads(int nThreads);

}
