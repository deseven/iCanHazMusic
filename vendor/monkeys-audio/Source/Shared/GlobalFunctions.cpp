#include "All.h"
#include "GlobalFunctions.h"
#include "IAPEIO.h"
#if __cplusplus >= 201103L
    #include <thread>
#endif
#if !defined(PLATFORM_WINDOWS) || !defined(UNICODE)
    #include "CharacterHelper.h"
#endif

#ifdef PLATFORM_APPLE
    #include <AvailabilityMacros.h>
#endif

#ifdef PLATFORM_ANDROID
    #include <android/api-level.h>
#endif

namespace APE
{

int ReadSafe(IAPEIO * pIO, void * pBuffer, int64 nBytes)
{
    int64 nBytesRead = 0;
    int nResult = pIO->Read(pBuffer, nBytes, &nBytesRead);
    if (nResult == APE_ERROR_SUCCESS)
    {
        if (nBytes != nBytesRead)
            nResult = APE_ERROR_IO_READ;
    }

    return nResult;
}

void * AllocateAligned(intn nBytes, intn nAlignment)
{
#if defined(PLATFORM_WINDOWS)
    return _aligned_malloc(static_cast<size_t>(nBytes), static_cast<size_t>(nAlignment));
#elif defined(PLATFORM_APPLE) && (MAC_OS_X_VERSION_MIN_REQUIRED < 1060)
    if (nAlignment <= 16)
        return malloc(nBytes);
    return valloc(nBytes);
#elif defined(PLATFORM_ANDROID) && (__ANDROID_API__ < 21)
    return memalign(nAlignment, nBytes);
#else
    void * pMemory = APE_NULL;
    if (posix_memalign(&pMemory, nAlignment, nBytes))
        return APE_NULL;
    return pMemory;
#endif
}

void FreeAligned(void * pMemory)
{
#ifdef PLATFORM_WINDOWS
    _aligned_free(pMemory);
#else
    free(pMemory);
#endif
}

bool StringIsEqual(const str_utfn * pString1, const str_utfn * pString2, bool bCaseSensitive, int nCharacters)
{
    // wcscasecmp isn't available on OSX 10.6 and sometimes it's hard to find other string comparisons that work reliably on different
    // platforms, so we'll just roll our own simple version here (performance of this function isn't critical to APE performance)

    // default to 'true' so that comparing two empty strings will be a match
    bool bResult = true;

    // if -1 is passed in, compare the entire string
    if (nCharacters == -1)
        nCharacters = 0x7FFFFFFF;

    if (nCharacters > 0)
    {
        // walk string
        str_utfn f, l;
        do
        {
            f = *pString1++;
            l = *pString2++;
            if (!bCaseSensitive)
            {
                f = towlower(f);
                l = towlower(l);
            }
        }
        while ((--nCharacters) && (f != 0) && (f == l));

        // if we're still equal, it's a match
        bResult = (f == l);
    }

    return bResult;
}

void SwitchBufferBytes(void * pBuffer, int nBytesPerBlock, int nBlocks)
{
    if (nBytesPerBlock == 2)
    {
        uint16 * pShortBuffer = static_cast<uint16 *>(pBuffer);
        for (int i = 0; i < nBlocks; i++)
            pShortBuffer[i] = Switch2Bytes(pShortBuffer[i]);
    }
    else if (nBytesPerBlock == 3)
    {
        uint8 * pByteBuffer = static_cast<uint8 *>(pBuffer);
        for (int i = 0; i < nBlocks * nBytesPerBlock; i += nBytesPerBlock)
        {
            uint8 nTemp = pByteBuffer[i];
            pByteBuffer[i    ] = pByteBuffer[i + 2];
            pByteBuffer[i + 2] = nTemp;
        }
    }
    else if (nBytesPerBlock == 4)
    {
        uint32 * pLongBuffer = static_cast<uint32 *>(pBuffer);
        for (int i = 0; i < nBlocks; i++)
            pLongBuffer[i] = Switch4Bytes(pLongBuffer[i]);
    }
}

int GetNumberThreads(int nThreads)
{
    if (nThreads == APE_THREADS_AUTOMATIC)
    {
        #if __cplusplus >= 201103L
            nThreads = APE_MAX(1, static_cast<int>(std::thread::hardware_concurrency()) / 2);
        #else
            nThreads = 1;
        #endif
    }
    nThreads = APE_CAP(nThreads, 1, 32);
    return nThreads;
}

}
