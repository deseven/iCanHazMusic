#include "All.h"
#include "MACLib.h"
#include "APECompress.h"
#include "APEDecompress.h"
#include "APELink.h"
#include "GlobalFunctions.h"
#include "MACProgressHelper.h"
#include "CharacterHelper.h"
#include "WAVInputSource.h"
#include "MD5.h"
#include "APEInfo.h"
#include "APETag.h"
#if defined(IO_USE_WIN_FILE_IO)
    #include "WinFileIO.h"
#elif defined(IO_USE_STD_LIB_FILE_IO)
    #include "StdLibFileIO.h"
#endif
#ifdef APE_BACKWARDS_COMPATIBILITY
    #include "Old/APEDecompressOld.h"
#endif

using namespace APE;

#define APE_DECODER_OUTPUT_NONE       0
#define APE_DECODER_OUTPUT_WAV        1
#define APE_DECODER_OUTPUT_APE        2

#define APE_BLOCKS_PER_DECODE         9216

IAPEDecompress * CreateIAPEDecompressCore(IAPEInfo * pAPEInfo, int nStartBlock, int nFinishBlock, int * pErrorCode);
int DecompressCore(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, int nOutputMode, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, IAPEDecompress * pDecompress, int nThreads);

/**************************************************************************************************
Functions to create the interfaces
**************************************************************************************************/
IAPEDecompress * CreateIAPEDecompressCore(IAPEInfo * pAPEInfo, int nStartBlock, int nFinishBlock, int * pErrorCode)
{
    // create the decompressor (this eats the CAPEInfo object)
    CSmartPtr<IAPEDecompress> spAPEDecompress;

    // proceed if we have an info object
    if (pAPEInfo != APE_NULL)
    {
        // proceed if there's no error with the info object
        if (*pErrorCode == APE_ERROR_SUCCESS)
        {
            try
            {
                // create
                const int nVersion = static_cast<int>(pAPEInfo->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION));
                if ((nVersion >= 3990) && (nVersion <= APE_FILE_VERSION_NUMBER))
                    spAPEDecompress.Assign(new CAPEDecompress(pErrorCode, pAPEInfo, nStartBlock, nFinishBlock));
                else if (nVersion == 4110)
                    spAPEDecompress.Assign(new CAPEDecompress(pErrorCode, pAPEInfo, nStartBlock, nFinishBlock)); // a few users have mailed me files with this version -- I don't know where they came from but they verify fine using this code
#ifdef APE_BACKWARDS_COMPATIBILITY
                else if ((nVersion >= 3930) && (nVersion <= APE_FILE_VERSION_NUMBER))
                    spAPEDecompress.Assign(new CAPEDecompress(pErrorCode, pAPEInfo, nStartBlock, nFinishBlock));
                else if (nVersion < 3930)
                    spAPEDecompress.Assign(new CAPEDecompressOld(pErrorCode, pAPEInfo, nStartBlock, nFinishBlock));
#endif
                else
                    *pErrorCode = APE_ERROR_UNSUPPORTED_FILE_VERSION;

                // error check
                if (spAPEDecompress == APE_NULL || *pErrorCode != APE_ERROR_SUCCESS)
                {
                    spAPEDecompress.Delete();
                }
            }
            catch(...)
            {
                spAPEDecompress.Delete();
                *pErrorCode = APE_ERROR_UNDEFINED;
            }
        }
        else
        {
            // eat the CAPEInfo object if we didn't create a decompressor
            APE_SAFE_DELETE(pAPEInfo)
        }
    }

    // return
    spAPEDecompress.SetDelete(false);
    return spAPEDecompress.GetPtr();
}

IAPETag * __stdcall CreateIAPETagFromIO(IAPEIO * pIO, bool bAnalyze, bool bCheckForID3v1)
{
    return new CAPETag(pIO, bAnalyze, bCheckForID3v1);
}

IAPETag * __stdcall CreateIAPETagFromFilename(const str_utfn * pFilename, bool bAnalyze)
{
    return new CAPETag(pFilename, bAnalyze);
}

IAPEInfo * __stdcall CreateIAPEInfo(int * pErrorCode, APE::IAPEIO * pIO)
{
    IAPEInfo * pInfo = new CAPEInfo(pErrorCode, pIO, APE_NULL);
    return pInfo;
}

IAPEDecompress * __stdcall CreateIAPEDecompress(const str_utfn * pFilename, int * pErrorCode, bool bReadOnly, bool bAnalyzeTagNow, bool bReadWholeFile)
{
    // error check the parameters
    if ((pFilename == APE_NULL) || (wcslen(pFilename) == 0))
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_BAD_PARAMETER;
        return APE_NULL;
    }

    // variables
    int nErrorCode = APE_ERROR_UNDEFINED;
    CAPEInfo * pAPEInfo = APE_NULL;
    int nStartBlock = -1; int nFinishBlock = -1;

    // get the extension
    const str_utfn * pExtension = &pFilename[wcslen(pFilename)];
    while ((pExtension > pFilename) && (*pExtension != '.'))
        pExtension--;

    // take the appropriate action (based on the extension)
    if (StringIsEqual(pExtension, L".apl", false))
    {
        // "link" file (.apl linked large APE file)
        CAPELink APELink(pFilename);
        if (APELink.GetIsLinkFile())
        {
            pAPEInfo = new CAPEInfo(&nErrorCode, APELink.GetImageFilename(), new CAPETag(pFilename, true), true);
            if (nErrorCode != APE_ERROR_SUCCESS)
            {
                APE_SAFE_DELETE(pAPEInfo)
                if (pErrorCode) *pErrorCode = nErrorCode;
                return APE_NULL;
            }
            nStartBlock = APELink.GetStartBlock(); nFinishBlock = APELink.GetFinishBlock();
        }
    }
    else if (StringIsEqual(pExtension, L".mac", false) || StringIsEqual(pExtension, L".ape", false) || StringIsEqual(pFilename, L"-", false))
    {
        // plain .ape file (we assume data coming in from a pipe is this type)
        pAPEInfo = new CAPEInfo(&nErrorCode, pFilename, APE_NULL, false, bReadOnly, bAnalyzeTagNow, bReadWholeFile);
        if (nErrorCode != APE_ERROR_SUCCESS)
        {
            APE_SAFE_DELETE(pAPEInfo)
            if (pErrorCode) *pErrorCode = nErrorCode;
            return APE_NULL;
        }
    }

    // fail if we couldn't get the file information
    if (pAPEInfo == APE_NULL)
    {
        if (pErrorCode) *pErrorCode = APE_ERROR_INVALID_INPUT_FILE;
        return APE_NULL;
    }

    // create
    nErrorCode = APE_ERROR_SUCCESS;
    IAPEDecompress * pAPEDecompress = CreateIAPEDecompressCore(pAPEInfo, nStartBlock, nFinishBlock, &nErrorCode);
    if (pErrorCode) *pErrorCode = nErrorCode;

    // return
    return pAPEDecompress;
}

IAPEDecompress * __stdcall CreateIAPEDecompressEx(IAPEIO * pIO, int * pErrorCode)
{
    // create info
    int nErrorCode = APE_ERROR_UNDEFINED;
    CAPEInfo * pAPEInfo = new CAPEInfo(&nErrorCode, pIO);

    // create decompress core
    IAPEDecompress * pAPEDecompress = CreateIAPEDecompressCore(pAPEInfo, -1, -1, &nErrorCode);
    if (pErrorCode) *pErrorCode = nErrorCode;

    // return
    return pAPEDecompress;
}

IAPEDecompress * __stdcall CreateIAPEDecompressEx2(IAPEInfo * pAPEInfo, int nStartBlock, int nFinishBlock, int * pErrorCode)
{
    int nErrorCode = APE_ERROR_SUCCESS;
    IAPEDecompress * pAPEDecompress = CreateIAPEDecompressCore(pAPEInfo, nStartBlock, nFinishBlock, &nErrorCode);
    if (pErrorCode) *pErrorCode = nErrorCode;

    return pAPEDecompress;
}

#ifdef APE_SUPPORT_COMPRESS
IAPECompress * __stdcall CreateIAPECompress(int * pErrorCode)
{
    if (pErrorCode)
        *pErrorCode = APE_ERROR_SUCCESS;

    return new CAPECompress();
}
#endif

APE::str_utf8 * __stdcall GetUTF8FromUTFN(const APE::str_utfn * pUTFN)
{
    return CAPECharacterHelper::GetUTF8FromUTFN(pUTFN);
}

APE::str_utfn * __stdcall GetUTFNFromUTF8(const APE::str_utf8 * pUTF8)
{
    return CAPECharacterHelper::GetUTFNFromUTF8(pUTF8);
}

/**************************************************************************************************
Fill wave headers
**************************************************************************************************/
APE::IAPEIO * __stdcall CreateIAPEIO()
{
#if defined(IO_USE_WIN_FILE_IO)
    return new CWinFileIO;
#elif defined(IO_USE_STD_LIB_FILE_IO)
    return new CStdLibFileIO;
#else
    return APE_NULL;
#endif
}

int __stdcall FillWaveFormatEx(APE::WAVEFORMATEX * pWaveFormatEx, int nFormatTag, int nSampleRate, int nBitsPerSample, int nChannels)
{
    pWaveFormatEx->cbSize = 0;
    pWaveFormatEx->nSamplesPerSec = static_cast<uint32>(nSampleRate);
    pWaveFormatEx->wBitsPerSample = static_cast<WORD>(nBitsPerSample);
    pWaveFormatEx->nChannels = static_cast<WORD>(nChannels);
    pWaveFormatEx->wFormatTag = static_cast<WORD>(nFormatTag);

    pWaveFormatEx->nBlockAlign = static_cast<WORD>((pWaveFormatEx->wBitsPerSample / 8) * pWaveFormatEx->nChannels);
    pWaveFormatEx->nAvgBytesPerSec = pWaveFormatEx->nBlockAlign * pWaveFormatEx->nSamplesPerSec;

    return APE_ERROR_SUCCESS;
}

int __stdcall FillWaveHeader(WAVE_HEADER * pWAVHeader, APE::int64 nAudioBytes, const APE::WAVEFORMATEX * pWaveFormatEx, APE::intn nTerminatingBytes)
{
    try
    {
        // RIFF header
        memcpy(pWAVHeader->cRIFFHeader, "RIFF", 4);
        pWAVHeader->nRIFFBytes = static_cast<unsigned int>((nAudioBytes + 44) - 8 + nTerminatingBytes);

        // format header
        memcpy(pWAVHeader->cDataTypeID, "WAVE", 4);
        memcpy(pWAVHeader->cFormatHeader, "fmt ", 4);

        // the format chunk is the first 16 bytes of a waveformatex
        pWAVHeader->nFormatBytes = 16;
        memcpy(&pWAVHeader->nFormatTag, pWaveFormatEx, 16);

        // the data header
        memcpy(pWAVHeader->cDataHeader, "data", 4);
        if (nAudioBytes >= 0xFFFFFFFF)
            pWAVHeader->nDataBytes = static_cast<unsigned int>(-1);
        else
            pWAVHeader->nDataBytes = static_cast<unsigned int>(nAudioBytes);

        return APE_ERROR_SUCCESS;
    }
    catch(...) { return APE_ERROR_UNDEFINED; }
}

int __stdcall FillRF64Header(RF64_HEADER * pWAVHeader, APE::int64 nAudioBytes, const APE::WAVEFORMATEX * pWaveFormatEx)
{
    try
    {
        // RIFF header
        memcpy(pWAVHeader->cRIFFHeader, "RF64", 4);
        pWAVHeader->nRIFFBytes = static_cast<unsigned int>(-1); // only used for big files

        // WAV header
        memcpy(pWAVHeader->cDataTypeID, "WAVE", 4);

        // DS64 header
        memcpy(pWAVHeader->cDS64, "ds64", 4);
        pWAVHeader->nDSHeaderSize = static_cast<int>(reinterpret_cast<char *>(&pWAVHeader->cFormatHeader) - reinterpret_cast<char *>(&pWAVHeader->nRIFFSize)); // size between nRIFFSize and nTableLength (cFormatHeader is just after nTableLength)
        pWAVHeader->nRIFFSize = static_cast<int64>(sizeof(RF64_HEADER)) + nAudioBytes - 8; // size of entire ds64 chunk minus the very header
        pWAVHeader->nDataSize = nAudioBytes;
        pWAVHeader->nSampleCount = nAudioBytes / pWaveFormatEx->nBlockAlign; // it's called sample count, but David Bryant puts blocks in WavPack so I'll do the same
        pWAVHeader->nTableLength = 0;

        // format header
        memcpy(pWAVHeader->cFormatHeader, "fmt ", 4);

        // the format chunk is the first 16 bytes of a waveformatex
        pWAVHeader->nFormatBytes = 16;
        memcpy(&pWAVHeader->nFormatTag, pWaveFormatEx, 16);

        // the data header
        memcpy(pWAVHeader->cDataHeader, "data", 4);
        if (nAudioBytes >= 0xFFFFFFFF)
            pWAVHeader->nDataBytes = static_cast<unsigned int>(-1);
        else
            pWAVHeader->nDataBytes = static_cast<unsigned int>(nAudioBytes);

        return APE_ERROR_SUCCESS;
    }
    catch(...) { return APE_ERROR_UNDEFINED; }
}

int __stdcall GetAPEFileType(const APE::str_utfn * pInputFilename, APE::str_ansi cFileType[8])
{
    APE_CLEAR_ARRAY(cFileType, 8);

    int nErrorCode = 0;
    CAPEInfo Info(&nErrorCode, pInputFilename, APE_NULL, false, true, false);

    // customize the type if we're AIFF, W64, etc.
    int64 nFormat = Info.GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS);
    if (nFormat & APE_FORMAT_FLAG_AIFF)
    {
        strcpy_s(cFileType, 8, ".aiff");
    }
    else if (nFormat & APE_FORMAT_FLAG_W64)
    {
        strcpy_s(cFileType, 8, ".w64");
    }
    else if (nFormat & APE_FORMAT_FLAG_SND)
    {
        strcpy_s(cFileType, 8, ".snd");
    }
    else if (nFormat & APE_FORMAT_FLAG_CAF)
    {
        strcpy_s(cFileType, 8, ".caf");
    }
    else
    {
        strcpy_s(cFileType, 8, ".wav");
    }

    return APE_ERROR_SUCCESS;
}

void __stdcall GetAPECompressionLevelName(int nCompressionLevel, APE::str_utfn * pCompressionLevel, size_t nBufferCharacters, bool bTitleCase)
{
    if (nBufferCharacters < 16) return; // just do a quick check since wcscpy_s crashes when you over copy
    switch (nCompressionLevel)
    {
        case 1000: wcscpy_s(pCompressionLevel, nBufferCharacters, bTitleCase ? L"Fast" : L"fast"); break;
        case 2000: wcscpy_s(pCompressionLevel, nBufferCharacters, bTitleCase ? L"Normal" : L"normal"); break;
        case 3000: wcscpy_s(pCompressionLevel, nBufferCharacters, bTitleCase ? L"High" : L"high"); break;
        case 4000: wcscpy_s(pCompressionLevel, nBufferCharacters, bTitleCase ? L"Extra High" : L"extra high"); break;
        case 5000: wcscpy_s(pCompressionLevel, nBufferCharacters, bTitleCase ? L"Insane" : L"insane"); break;
        default: wcscpy_s(pCompressionLevel, nBufferCharacters, bTitleCase ? L"Unknown" : L"unknown"); break;
    }
}

void __stdcall GetAPEModeName(APE::APE_MODES Mode, APE::str_utfn * pModeName, size_t nBufferCharacters, bool bActive)
{
    if (nBufferCharacters < 16) return; // just do a quick check since wcscpy_s crashes when you over copy
    switch (Mode)
    {
        case MODE_COMPRESS: wcscpy_s(pModeName, nBufferCharacters, bActive ? L"Compressing" : L"Compress"); break;
        case MODE_DECOMPRESS: wcscpy_s(pModeName, nBufferCharacters, bActive ? L"Decompressing" : L"Decompress"); break;
        case MODE_VERIFY: wcscpy_s(pModeName, nBufferCharacters, bActive ? L"Verifying" : L"Verify"); break;
        case MODE_CONVERT: wcscpy_s(pModeName, nBufferCharacters, bActive ? L"Converting" : L"Convert"); break;
        case MODE_MAKE_APL: wcscpy_s(pModeName, nBufferCharacters, bActive ? L"Making APL's" : L"Make APL's"); break;
        // all other conditions to prevent compiler warnings (4061, 4062, and Clang)
        case MODE_CHECK:
        case MODE_COUNT: 
            break; // not used
    }
}

/**************************************************************************************************
ANSI wrappers
**************************************************************************************************/
#ifdef APE_SUPPORT_COMPRESS
int __stdcall CompressFile(const APE::str_ansi * pInputFilename, const APE::str_ansi * pOutputFilename, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads, IID3v2Tag * pTag)
{
    CSmartPtr<str_utfn> spInputFile(CAPECharacterHelper::GetUTFNFromANSI(pInputFilename), true);
    CSmartPtr<str_utfn> spOutputFile(CAPECharacterHelper::GetUTFNFromANSI(pOutputFilename), true);
    return CompressFileW(spInputFile, spOutputFile, nCompressionLevel, pProgressCallback, nThreads, pTag);
}
#endif

int __stdcall DecompressFile(const APE::str_ansi * pInputFilename, const APE::str_ansi * pOutputFilename, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads)
{
    if (pOutputFilename == APE_NULL)
    {
        CSmartPtr<str_utfn> spInputFile(CAPECharacterHelper::GetUTFNFromANSI(pInputFilename), true);
        return DecompressFileW(spInputFile, APE_NULL, pProgressCallback, nThreads);
    }
    else
    {
        CSmartPtr<str_utfn> spInputFile(CAPECharacterHelper::GetUTFNFromANSI(pInputFilename), true);
        CSmartPtr<str_utfn> spOutputFile(CAPECharacterHelper::GetUTFNFromANSI(pOutputFilename), true);
        return DecompressFileW(spInputFile, spOutputFile, pProgressCallback, nThreads);
    }
}

int __stdcall ConvertFile(const APE::str_ansi * pInputFilename, const APE::str_ansi * pOutputFilename, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads)
{
    CSmartPtr<str_utfn> spInputFile(CAPECharacterHelper::GetUTFNFromANSI(pInputFilename), true);
    CSmartPtr<str_utfn> spOutputFile(CAPECharacterHelper::GetUTFNFromANSI(pOutputFilename), true);
    return ConvertFileW(spInputFile, spOutputFile, nCompressionLevel, pProgressCallback, nThreads);
}

int __stdcall VerifyFile(const APE::str_ansi * pInputFilename, APE::CAPEProgressCallbackInfo * pProgressCallback, bool bQuickVerifyIfPossible, int nThreads)
{
    CSmartPtr<str_utfn> spInputFile(CAPECharacterHelper::GetUTFNFromANSI(pInputFilename), true);
    return VerifyFileW(spInputFile, pProgressCallback, bQuickVerifyIfPossible, nThreads);
}

/**************************************************************************************************
Legacy callback wrappers
**************************************************************************************************/
#ifdef APE_SUPPORT_COMPRESS
int __stdcall CompressFileW(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads, APE::IID3v2Tag * pTag, bool bReadFullInputForUnknownLength)
{
    return CompressFileW2(pInputFilename, pOutputFilename, nCompressionLevel, pProgressCallback, nThreads, pTag, bReadFullInputForUnknownLength);
}
#endif

int __stdcall VerifyFileW(const APE::str_utfn * pInputFilename, APE::CAPEProgressCallbackInfo * pProgressCallback, bool bQuickVerifyIfPossible, int nThreads)
{
    return VerifyFileW2(pInputFilename, pProgressCallback, bQuickVerifyIfPossible, nThreads);
}

int __stdcall DecompressFileW(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads)
{
    const int nResult = DecompressFileW2(pInputFilename, pOutputFilename, pProgressCallback, nThreads);
    return nResult;
}

int __stdcall ConvertFileW(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads)
{
    return ConvertFileW2(pInputFilename, pOutputFilename, nCompressionLevel, pProgressCallback, nThreads);
}

/**************************************************************************************************
Compress file
**************************************************************************************************/
#ifdef APE_SUPPORT_COMPRESS
int __stdcall CompressFileW2(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads, APE::IID3v2Tag * pTag, bool bReadFullInputForUnknownLength)
{
    // declare the variables
    int nFunctionRetVal = APE_ERROR_SUCCESS;
    APE::WAVEFORMATEX WaveFormatEx;
    CSmartPtr<CMACProgressHelper> spMACProgressHelper;
    CSmartPtr<unsigned char> spBuffer;
    CSmartPtr<IAPECompress> spAPECompress;

    try
    {
        // create the input source
        int nResult = APE_ERROR_UNDEFINED;
        int64 nAudioBlocks = 0; int64 nHeaderBytes = 0; int64 nTerminatingBytes = 0; int32 nFlags = 0;
        CSmartPtr<CInputSource> spInputSource(CInputSource::CreateInputSource(pInputFilename, &WaveFormatEx, &nAudioBlocks,
            &nHeaderBytes, &nTerminatingBytes, &nFlags, pTag, bReadFullInputForUnknownLength, &nResult));

        // check header and footer sizes right away (we also check the footer at the end, but that would require compressing the whole file then rejecting)
        if ((nHeaderBytes > APE_WAV_HEADER_OR_FOOTER_MAXIMUM_BYTES) ||
            (nTerminatingBytes > APE_WAV_HEADER_OR_FOOTER_MAXIMUM_BYTES))
        {
            throw static_cast<intn>(APE_ERROR_INPUT_FILE_TOO_LARGE);
        }

        if ((spInputSource == APE_NULL) || (nResult != APE_ERROR_SUCCESS))
            throw static_cast<intn>(nResult);

        // create the compressor
        spAPECompress.Assign(CreateIAPECompress());
        if (spAPECompress == APE_NULL) throw static_cast<intn>(APE_ERROR_UNDEFINED);

        // set the threads
        spAPECompress->SetNumberOfThreads(nThreads);

        // figure the audio bytes
        int64 nAudioBytes = static_cast<int64>(nAudioBlocks) * static_cast<int64>(WaveFormatEx.nBlockAlign);
        if (spInputSource->GetUnknownLengthFile())
            nAudioBytes = APE_MAX_AUDIO_BYTES_UNKNOWN;
        if ((nAudioBytes <= 0) && (nAudioBytes != APE_MAX_AUDIO_BYTES_UNKNOWN))
            throw static_cast<intn>(APE_ERROR_INPUT_FILE_TOO_SMALL);

        // get the header data
        if (nHeaderBytes > 0) spBuffer.AllocateArray(nHeaderBytes);
        APE_THROW_ON_ERROR(spInputSource->GetHeaderData(spBuffer.GetPtr()))

        // start the encoder
        APE_THROW_ON_ERROR(spAPECompress->Start(pOutputFilename, &WaveFormatEx, spInputSource->GetFloat(), nAudioBytes, nCompressionLevel, spBuffer.GetPtr(), nHeaderBytes, nFlags))
        spBuffer.Delete();

        // set-up the progress
        spMACProgressHelper.Assign(new CMACProgressHelper(nAudioBytes, pProgressCallback));

        // master loop
        int64 nBytesLeft = nAudioBytes;
        const bool bUnknownLengthFile = spInputSource->GetUnknownLengthFile();
        while ((nBytesLeft > 0) || bUnknownLengthFile)
        {
            // add data
            int64 nBytesAdded = 0;
            const int64 nRetVal = spAPECompress->AddDataFromInputSource(spInputSource.GetPtr(), nBytesLeft, &nBytesAdded);
            if (bUnknownLengthFile && (nRetVal == APE_ERROR_IO_READ))
                break; // this means we reached the end of the file
            else if (nRetVal != APE_ERROR_SUCCESS)
                throw(static_cast<intn>(nRetVal));
            nBytesLeft -= nBytesAdded;

            // update the progress
            if (nAudioBytes != -1)
                spMACProgressHelper->UpdateProgress(nAudioBytes - nBytesLeft);

            // process the kill flag
            if (spMACProgressHelper->ProcessKillFlag() != APE_ERROR_SUCCESS)
                throw(static_cast<intn>(APE_ERROR_USER_STOPPED_PROCESSING));
        }

        // finalize the file
        if (nTerminatingBytes > 0)
        {
            spBuffer.AllocateArray(nTerminatingBytes);
            APE_THROW_ON_ERROR(spInputSource->GetTerminatingData(spBuffer.GetPtr()))
        }
        APE_THROW_ON_ERROR(spAPECompress->Finish(spBuffer.GetPtr(), nTerminatingBytes, nTerminatingBytes))

        // update the progress to 100%
        spMACProgressHelper->UpdateProgressComplete();
    }
    catch (const intn nErrorCode)
    {
        nFunctionRetVal = (nErrorCode == 0) ? APE_ERROR_UNDEFINED : static_cast<int>(nErrorCode);
    }
    catch (...)
    {
        nFunctionRetVal = APE_ERROR_UNDEFINED;
    }

    // return
    return nFunctionRetVal;
}
#endif

/**************************************************************************************************
Verify file
**************************************************************************************************/
int __stdcall VerifyFileW2(const APE::str_utfn * pInputFilename, CAPEProgressCallbackInfo * pProgressCallback, bool bQuickVerifyIfPossible, int nThreads)
{
    // error check the function parameters
    if (pInputFilename == APE_NULL)
    {
        return APE_ERROR_INVALID_FUNCTION_PARAMETER;
    }

    // return value
    int nResult = APE_ERROR_UNDEFINED;

    // see if we can quick verify
    CSmartPtr<IAPEDecompress> spAPEDecompress;
    if (bQuickVerifyIfPossible)
    {
        try
        {
            // create decompress core
            int nFunctionRetVal = APE_ERROR_SUCCESS;
            spAPEDecompress.Assign(CreateIAPEDecompress(pInputFilename, &nFunctionRetVal, true, false, true));
            if (spAPEDecompress == APE_NULL || nFunctionRetVal != APE_ERROR_SUCCESS) throw(static_cast<intn>(nFunctionRetVal));

            // if we're an APL file, we need to slow verify since we're just a little chunk in a big file
            // in the past we would just check the whole file with a quick verify, but slow verify seems better in this case
            if (spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_APL))
                throw(static_cast<intn>(APE_ERROR_UNSUPPORTED_FILE_TYPE));

            // get info object from the decompress core
            const APE_FILE_INFO * pInfo = spAPEDecompress->GetFileInfo();

            // check version
            if ((pInfo->nVersionEncoder < 3980) || (pInfo->spAPEDescriptor == APE_NULL))
                throw(static_cast<intn>(APE_ERROR_UNSUPPORTED_FILE_VERSION));

            // set the threads
            spAPEDecompress->SetNumberOfThreads(nThreads);
        }
        catch (...)
        {
            bQuickVerifyIfPossible = false;
        }
    }

    // if we can and should quick verify, then do it
    if (bQuickVerifyIfPossible)
    {
        // variable declares
        int nFunctionRetVal = APE_ERROR_SUCCESS;

        // run the quick verify
        try
        {
            CMD5Helper MD5Helper;
            int64 nBytesRead = 0;

            IAPEIO * pIO = spAPEDecompress->GetIO();
            const APE_FILE_INFO * pInfo = spAPEDecompress->GetFileInfo();

            if ((pInfo->nVersionEncoder < 3980) || (pInfo->spAPEDescriptor == APE_NULL))
                throw(static_cast<intn>(APE_ERROR_UNSUPPORTED_FILE_VERSION));

            // read APE header
            CSmartPtr<unsigned char> spAPEHeader(pInfo->spAPEDescriptor->nHeaderBytes);
            pIO->Seek(static_cast<int64>(pInfo->nJunkHeaderBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nDescriptorBytes), SeekFileBegin);
            APE_THROW_ON_ERROR(pIO->Read(spAPEHeader, pInfo->spAPEDescriptor->nHeaderBytes, &nBytesRead))

            // read seek table
            CSmartPtr<unsigned char> spSeekTable(pInfo->spAPEDescriptor->nSeekTableBytes);
            ASSERT(pIO->GetPosition() == (static_cast<int64>(pInfo->nJunkHeaderBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nDescriptorBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nHeaderBytes)));
            APE_THROW_ON_ERROR(pIO->Read(spSeekTable, pInfo->spAPEDescriptor->nSeekTableBytes, &nBytesRead))

            // read header data
            CSmartPtr<unsigned char> spHeader(pInfo->spAPEDescriptor->nHeaderDataBytes);
            ASSERT(pIO->GetPosition() == (static_cast<int64>(pInfo->nJunkHeaderBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nDescriptorBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nHeaderBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nSeekTableBytes)));
            APE_THROW_ON_ERROR(pIO->Read(spHeader, pInfo->spAPEDescriptor->nHeaderDataBytes, &nBytesRead))

            // seek to the data (we should already be there)
            ASSERT(pIO->GetPosition() == (static_cast<int64>(pInfo->nJunkHeaderBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nDescriptorBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nHeaderBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nSeekTableBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nHeaderDataBytes)));

            // add the WAV header to the MD5 first
            MD5Helper.AddData(spHeader, pInfo->spAPEDescriptor->nHeaderDataBytes);

            // bytes left
            int64 nBytesLeft = (static_cast<int64>(pInfo->spAPEDescriptor->nAPEFrameDataBytesHigh) << 32) + static_cast<int64>(pInfo->spAPEDescriptor->nAPEFrameDataBytes) + static_cast<int64>(pInfo->spAPEDescriptor->nTerminatingDataBytes);
            const int64 nBytesLeftOriginal = nBytesLeft;

            // read in smaller chunks
            CSmartPtr<CMACProgressHelper> spMACProgressHelper;
            spMACProgressHelper.Assign(new CMACProgressHelper(nBytesLeft, pProgressCallback));

            CSmartPtr<unsigned char> spBuffer(new unsigned char [16384], true);
            nBytesRead = 1;
            while ((nBytesLeft > 0) && (nBytesRead > 0))
            {
                const int64 nBytesToRead = APE_MIN<int64>(16384, nBytesLeft);
                if (pIO->Read(spBuffer, nBytesToRead, &nBytesRead) != APE_ERROR_SUCCESS)
                    throw(static_cast<intn>(APE_ERROR_IO_READ));

                MD5Helper.AddData(spBuffer, nBytesRead);
                spMACProgressHelper->UpdateProgress(nBytesLeftOriginal - nBytesLeft);

                nBytesLeft -= nBytesRead;

                if (spMACProgressHelper->ProcessKillFlag() != APE_ERROR_SUCCESS)
                    throw(static_cast<intn>(APE_ERROR_USER_STOPPED_PROCESSING));
            }

            if (nBytesLeft != 0)
                throw(static_cast<intn>(APE_ERROR_IO_READ));

            // add the header and seek table
            MD5Helper.AddData(spAPEHeader, pInfo->spAPEDescriptor->nHeaderBytes);
            MD5Helper.AddData(spSeekTable, pInfo->spAPEDescriptor->nSeekTableBytes);

            // get results
            unsigned char cResult[16];
            MD5Helper.GetResult(cResult);

            // compare to stored
            nFunctionRetVal = static_cast<int>(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_MD5_MATCHES, APE_POINTER_TO_INT64(&cResult[0])));

            // update the progress to 100%
            spMACProgressHelper->UpdateProgressComplete();
        }
        catch (const intn nErrorCode)
        {
            nFunctionRetVal = (nErrorCode == 0) ? APE_ERROR_UNDEFINED : static_cast<int>(nErrorCode);
        }
        catch (...)
        {
            nFunctionRetVal = APE_ERROR_UNDEFINED;
        }

        // return value
        nResult = nFunctionRetVal;
    }
    else
    {
        nResult = DecompressCore(pInputFilename, APE_NULL, APE_DECODER_OUTPUT_NONE, -1, pProgressCallback, spAPEDecompress, nThreads);
    }

    return nResult;
}

/**************************************************************************************************
Decompress file
**************************************************************************************************/
int __stdcall DecompressFileW2(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads)
{
    if (pOutputFilename == APE_NULL)
        return VerifyFileW2(pInputFilename, pProgressCallback);
    else
        return DecompressCore(pInputFilename, pOutputFilename, APE_DECODER_OUTPUT_WAV, -1, pProgressCallback, APE_NULL, nThreads);
}

/**************************************************************************************************
Convert file
**************************************************************************************************/
int __stdcall ConvertFileW2(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, int nThreads)
{
    return DecompressCore(pInputFilename, pOutputFilename, APE_DECODER_OUTPUT_APE, nCompressionLevel, pProgressCallback, APE_NULL, nThreads);
}

/**************************************************************************************************
Decompress a file using the specified output method
**************************************************************************************************/
int DecompressCore(const APE::str_utfn * pInputFilename, const APE::str_utfn * pOutputFilename, int nOutputMode, int nCompressionLevel, APE::CAPEProgressCallbackInfo * pProgressCallback, IAPEDecompress * pDecompress, int nThreads)
{
    // error check the function parameters
    if (pInputFilename == APE_NULL)
    {
        return APE_ERROR_INVALID_FUNCTION_PARAMETER;
    }

    // variable declares
    int nFunctionRetVal = APE_ERROR_SUCCESS;
    CSmartPtr<IAPEIO> spioOutput;
    CSmartPtr<IAPECompress> spAPECompress;
    CSmartPtr<IAPEDecompress> spAPEDecompress;
    CSmartPtr<unsigned char> spTempBuffer;
    CSmartPtr<CMACProgressHelper> spMACProgressHelper;
    APE::WAVEFORMATEX wfeInput;

    try
    {
        // create the decoder (or used the one passed in)
        if (pDecompress != APE_NULL)
        {
            spAPEDecompress.Assign(pDecompress, false, false);
        }
        else
        {
            spAPEDecompress.Assign(CreateIAPEDecompress(pInputFilename, &nFunctionRetVal, true, true, false));
        }
        if (spAPEDecompress == APE_NULL || nFunctionRetVal != APE_ERROR_SUCCESS) throw(static_cast<intn>(nFunctionRetVal));

        // set the threads
        spAPEDecompress->SetNumberOfThreads(nThreads);

        // get the input format
        APE_THROW_ON_ERROR(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAVEFORMATEX, APE_POINTER_TO_INT64(&wfeInput)))

        // allocate space for the header
        spTempBuffer.AllocateArray(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_HEADER_BYTES));
        if (spTempBuffer == APE_NULL) throw(static_cast<intn>(APE_ERROR_INSUFFICIENT_MEMORY));

        // get the header
        const int64 nHeaderBytes = spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_HEADER_BYTES);
        APE_THROW_ON_ERROR(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_HEADER_DATA, APE_POINTER_TO_INT64(spTempBuffer.GetPtr()), nHeaderBytes))

        // initialize the output
        if (nOutputMode == APE_DECODER_OUTPUT_WAV)
        {
            // create the file
            spioOutput.Assign(CreateIAPEIO()); APE_THROW_ON_ERROR(spioOutput->Create(pOutputFilename))

            // output the header
            APE_THROW_ON_ERROR(spioOutput->Write(spTempBuffer, spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_HEADER_BYTES)))
        }
#ifdef APE_SUPPORT_COMPRESS
        else if (nOutputMode == APE_DECODER_OUTPUT_APE)
        {
            // quit if there is nothing to do
            // no longer check when processing an APL since converting an APL to APE should work no matter what
            if ((spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION) == APE_FILE_VERSION_NUMBER) &&
                (spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_COMPRESSION_LEVEL) == nCompressionLevel) &&
                (spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_APL) == false))
            {
                throw(static_cast<intn>(APE_ERROR_SKIPPED));
            }

            // flags
            const int nSourceFlags = static_cast<int>(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS));
            const int nFlags = nSourceFlags;

            // originally just some flags were passed, but it seems like simply passing all of them is correct so that was changed on 3/6/2023
            //int nFlags = (nSourceFlags & MAC_FORMAT_FLAG_CAF) | (nSourceFlags & MAC_FORMAT_FLAG_SND) | (nSourceFlags & MAC_FORMAT_FLAG_W64) | (nSourceFlags & MAC_FORMAT_FLAG_AIFF);
            //nFlags |= (nSourceFlags & MAC_FORMAT_FLAG_SIGNED_8_BIT) | (nSourceFlags & MAC_FORMAT_FLAG_FLOATING_POINT);

            // create and start the compressor
            spAPECompress.Assign(CreateIAPECompress());
            APE_THROW_ON_ERROR(spAPECompress->Start(pOutputFilename, &wfeInput, spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_FLOATING_POINT,
                (spAPEDecompress->GetInfo(IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS) * spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCK_ALIGN)),
                nCompressionLevel, spTempBuffer, spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_HEADER_BYTES), nFlags))
        }
#endif

        // allocate space for decompression
        spTempBuffer.AllocateArray(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCK_ALIGN) * APE_BLOCKS_PER_DECODE);
        if (spTempBuffer == APE_NULL) throw(static_cast<intn>(APE_ERROR_INSUFFICIENT_MEMORY));

        int64 nBlocksLeft = static_cast<intn>(spAPEDecompress->GetInfo(IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS));

        // create the progress helper
        spMACProgressHelper.Assign(new CMACProgressHelper(nBlocksLeft / APE_BLOCKS_PER_DECODE, pProgressCallback));

        // processing flags
        IAPEDecompress::APE_GET_DATA_PROCESSING Processing = { true, (nOutputMode != APE_DECODER_OUTPUT_APE), (nOutputMode != APE_DECODER_OUTPUT_APE) };

        // main decoding loop
        while (nBlocksLeft > 0)
        {
            // decode data
            int64 nBlocksDecoded = -1;
            const int nResult = spAPEDecompress->GetData(spTempBuffer, APE_BLOCKS_PER_DECODE, &nBlocksDecoded, &Processing);
            if (nResult != APE_ERROR_SUCCESS)
                throw(static_cast<intn>(nResult));

            // handle the output
            if (nOutputMode == APE_DECODER_OUTPUT_WAV)
            {
#if APE_BYTE_ORDER == APE_BIG_ENDIAN
                if (wfeInput.wBitsPerSample >= 16)
                    SwitchBufferBytes(spTempBuffer, wfeInput.wBitsPerSample / 8, nBlocksDecoded * wfeInput.nChannels);
#endif
                const int64 nBytesToWrite = nBlocksDecoded * spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCK_ALIGN);
                const int nWriteResult = spioOutput->Write(spTempBuffer, nBytesToWrite);
                if (nWriteResult != APE_ERROR_SUCCESS)
                    throw(static_cast<intn>(APE_ERROR_IO_WRITE));
            }
            else if (nOutputMode == APE_DECODER_OUTPUT_APE)
            {
                APE_THROW_ON_ERROR(spAPECompress->AddData(spTempBuffer, (nBlocksDecoded * spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_BLOCK_ALIGN))))
            }

            // update amount remaining
            nBlocksLeft -= nBlocksDecoded;

            // update progress and kill flag
            spMACProgressHelper->UpdateProgress();
            if (spMACProgressHelper->ProcessKillFlag() != APE_ERROR_SUCCESS)
                throw(static_cast<intn>(APE_ERROR_USER_STOPPED_PROCESSING));
        }

        // terminate the output
        if (nOutputMode == APE_DECODER_OUTPUT_WAV)
        {
            // write any terminating WAV data
            if (spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES) > 0)
            {
                spTempBuffer.AllocateArray(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES));
                if (spTempBuffer == APE_NULL) throw(static_cast<intn>(APE_ERROR_INSUFFICIENT_MEMORY));
                APE_THROW_ON_ERROR(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_DATA, APE_POINTER_TO_INT64(spTempBuffer.GetPtr()), spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES)))

                const int64 nBytesToWrite = spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES);
                const int nResult = spioOutput->Write(spTempBuffer, nBytesToWrite);
                if (nResult != APE_ERROR_SUCCESS)
                    throw(static_cast<intn>(APE_ERROR_IO_WRITE));
            }
        }
        else if (nOutputMode == APE_DECODER_OUTPUT_APE)
        {
            // write the WAV data and any tag
            IAPETag * pAPETag = spAPEDecompress->GetTag();
            const int64 nTagBytes = (pAPETag != APE_NULL) ? pAPETag->GetTagBytes() : 0;
            const bool bHasTag = (nTagBytes > 0);
            int64 nTerminatingBytes = nTagBytes;
            nTerminatingBytes += static_cast<int>(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES));

            if (nTerminatingBytes > 0)
            {
                spTempBuffer.AllocateArray(nTerminatingBytes);
                if (spTempBuffer == APE_NULL) throw(static_cast<intn>(APE_ERROR_INSUFFICIENT_MEMORY));

                APE_THROW_ON_ERROR(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_DATA, APE_POINTER_TO_INT64(spTempBuffer.GetPtr()), nTerminatingBytes))

                if (bHasTag)
                {
                    IAPEIO * pIO = spAPEDecompress->GetIO();
                    APE_THROW_ON_ERROR(pIO->Seek(-nTagBytes, SeekFileEnd))
                    APE_THROW_ON_ERROR(pIO->Read(&spTempBuffer[spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES)], nTagBytes))
                }

                APE_THROW_ON_ERROR(spAPECompress->Finish(spTempBuffer, nTerminatingBytes, static_cast<int>(spAPEDecompress->GetInfo(IAPEDecompress::APE_INFO_WAV_TERMINATING_BYTES))))
            }
            else
            {
                APE_THROW_ON_ERROR(spAPECompress->Finish(APE_NULL, 0, 0))
            }
        }

        // fire the "complete" progress notification
        spMACProgressHelper->UpdateProgressComplete();

        // clean-up
        spAPEDecompress.Delete();
    }
    catch (const intn nErrorCode)
    {
        spAPEDecompress.Delete(); // delete explicitly (to avoid a crash on 2/23/2019 in release)
        nFunctionRetVal = (nErrorCode == 0) ? APE_ERROR_UNDEFINED : static_cast<int>(nErrorCode);
    }
    catch (...)
    {
        nFunctionRetVal = APE_ERROR_UNDEFINED;
    }

    // return
    return nFunctionRetVal;
}
