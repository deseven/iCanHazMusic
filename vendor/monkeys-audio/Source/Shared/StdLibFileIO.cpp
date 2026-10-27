#if defined(PLATFORM_APPLE) || defined(PLATFORM_ANDROID)
#define _FILE_OFFSET_BITS 64
#endif

#include "All.h"

#ifdef IO_USE_STD_LIB_FILE_IO

#include "StdLibFileIO.h"
#include "CharacterHelper.h"

///////////////////////////////////////////////////////

// low level I/O, where are prototypes and constants?
#if   defined _WIN32  ||  defined __TURBOC__  ||  defined __ZTC__  ||  defined _MSC_VER
# include <io.h>
# include <fcntl.h>
# include <time.h>
# include <sys/types.h>
# include <sys/stat.h>
#elif defined __unix__  ||  defined __linux__
# include <errno.h>
# include <fcntl.h>
# include <unistd.h>
# include <sys/time.h>
# include <sys/ioctl.h>
# include <sys/types.h>
# include <sys/stat.h>
#else
# include <errno.h>
# include <fcntl.h>
# include <unistd.h>
# include <sys/ioctl.h>
# include <sys/stat.h>
#endif


#ifndef O_BINARY
# ifdef _O_BINARY
#  define O_BINARY              _O_BINARY
# else
#  define O_BINARY              0
# endif
#endif

//// Binary/Low-Level-IO ///////////////////////////////////////////
//
// All file I/O is basicly handled via an ANSI file pointer (type: FILE *) in
// FILEIO-Mode 1 and via a POSIX file descriptor (type: int) in
// FILEIO-Mode 2 and 3.
//
// Some operation are only available via the POSIX interface (fcntl, setmode,
// ...) so we need a function to get the file descriptor from a file pointer.
// In FILEIO-Mode 2 and 3 this is a dummy function because we always working
// with this file descriptors.
//

#if   defined __BORLANDC__  ||  defined _WIN32
# define FILENO(__fp)          _fileno ((__fp))
#elif defined __CYGWIN__  ||  defined __TURBOC__  ||  defined __unix__  ||  defined __EMX__  ||  defined _MSC_VER
# define FILENO(__fp)          fileno  ((__fp))
#else
# define FILENO(__fp)          fileno  ((__fp))
#endif


//
// If we have access to a file via file name, we can open the file with an
// additional "b" or a O_BINARY within the (f)open function to get a
// transparent untranslated data stream which is necessary for audio bitstream
// data and also for PCM data. If we are working with
// stdin/stdout/FILENO_STDIN/FILENO_STDOUT we can't open the file with this
// attributes, because the files are already open. So we need a non
// standardized sequence to switch to this mode (not necessary for Unix).
// Mostly the sequency is the same for incoming and outgoing streams, but only
// mostly so we need one for IN and one for OUT.
// Macros are called with the file pointer and you get back the untransalted file
// pointer which can be equal or different from the original.
//

#if   defined __EMX__
# define SETBINARY_IN(__fp)     (_fsetmode ( (__fp), "b" ), (__fp))
# define SETBINARY_OUT(__fp)    (_fsetmode ( (__fp), "b" ), (__fp))
#elif defined __TURBOC__ || defined __BORLANDC__
# define SETBINARY_IN(__fp)     (setmode   ( FILENO ((__fp)),  O_BINARY ), (__fp))
# define SETBINARY_OUT(__fp)    (setmode   ( FILENO ((__fp)),  O_BINARY ), (__fp))
#elif defined __CYGWIN__
# define SETBINARY_IN(__fp)     (setmode   ( FILENO ((__fp)), _O_BINARY ), (__fp))
# define SETBINARY_OUT(__fp)    (setmode   ( FILENO ((__fp)), _O_BINARY ), (__fp))
#elif defined _WIN32
# define SETBINARY_IN(__fp)     (_setmode  ( FILENO ((__fp)), _O_BINARY ), (__fp))
# define SETBINARY_OUT(__fp)    (_setmode  ( FILENO ((__fp)), _O_BINARY ), (__fp))
#elif defined _MSC_VER
# define SETBINARY_IN(__fp)     (setmode   ( FILENO ((__fp)),  O_BINARY ), (__fp))
# define SETBINARY_OUT(__fp)    (setmode   ( FILENO ((__fp)),  O_BINARY ), (__fp))
#elif defined __unix__
# define SETBINARY_IN(__fp)     (__fp)
# define SETBINARY_OUT(__fp)    (__fp)
#elif 0
# define SETBINARY_IN(__fp)     (freopen   ( APE_NULL, "rb", (__fp) ), (__fp))
# define SETBINARY_OUT(__fp)    (freopen   ( APE_NULL, "wb", (__fp) ), (__fp))
#else
# define SETBINARY_IN(__fp)     (__fp)
# define SETBINARY_OUT(__fp)    (__fp)
#endif

namespace APE
{

CStdLibFileIO::CStdLibFileIO()
{
    m_bReadOnly = false;
    m_bPipe = false;
    m_pFile = APE_NULL;
}

CStdLibFileIO::~CStdLibFileIO()
{
    Close();
}

int CStdLibFileIO::GetHandle()
{
    return FILENO(m_pFile);
}

int CStdLibFileIO::Open(const str_utfn * pName, bool)
{
    Close();

    m_bReadOnly = false;

    if (0 == wcscmp(pName, L"-") || 0 == wcscmp(pName, L"/dev/stdin"))
    {
        m_pFile = SETBINARY_IN(stdin);
        m_bReadOnly = true;                                                     // ReadOnly
        m_bPipe = true;
    }
    else if (0 == wcscmp(pName, L"/dev/stdout"))
    {
        m_pFile = SETBINARY_OUT(stdout);
        m_bReadOnly = false;                                                    // WriteOnly
    }
    else
    {
        #ifdef PLATFORM_WINDOWS
            int nResult = _wfopen_s(&m_pFile, pName, L"r+bN");
        #else
            CSmartPtr<char> spFilenameUTF8((char *) CAPECharacterHelper::GetUTF8FromUTFN(pName), true);
            m_pFile = fopen(spFilenameUTF8, "r+be");
            int nResult = errno;
        #endif
        if ((m_pFile == APE_NULL) && (nResult == EACCES || nResult == EPERM || nResult == EROFS))
        {
            // failed asking for read/write mode on open, try read-only
            #ifdef PLATFORM_WINDOWS
                _wfopen_s(&m_pFile, pName, L"rbN");
            #else
                m_pFile = fopen(spFilenameUTF8, "rbe");
            #endif
            if (m_pFile)
                m_bReadOnly = true;
        }
    }

    if (!m_pFile)
        return APE_ERROR_UNDEFINED;

    m_spFileName.AllocateArray(static_cast<int>(wcslen(pName)) + 1);
    memcpy(m_spFileName.GetPtr(), pName, (wcslen(pName) + 1) * sizeof(str_utfn));

    return APE_ERROR_SUCCESS;
}

int CStdLibFileIO::Close()
{
    int nResult = APE_ERROR_UNDEFINED;

    if (m_pFile != APE_NULL)
    {
        nResult = fclose(m_pFile);
        m_pFile = APE_NULL;
    }

    return nResult;
}

int CStdLibFileIO::Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead)
{
    int64 nBytesRead = static_cast<int64>(fread(pBuffer, 1, static_cast<size_t>(nBytesToRead), m_pFile));
    if (pBytesRead != APE_NULL)
        *pBytesRead = nBytesRead;
    int nRetVal = APE_ERROR_SUCCESS;
    if ((nBytesRead == 0) && (nBytesToRead > 0))
        nRetVal = APE_ERROR_IO_READ;
    else if (ferror(m_pFile))
        nRetVal = APE_ERROR_IO_READ;
    return nRetVal;
}

int CStdLibFileIO::Write(const void * pBuffer, int64 nBytesToWrite, int64 * pBytesWritten)
{
    int64 nBytesWritten = static_cast<int64>(fwrite(pBuffer, 1, static_cast<size_t>(nBytesToWrite), m_pFile));
    if (pBytesWritten != APE_NULL)
        *pBytesWritten = nBytesWritten;
    return (ferror(m_pFile) || (nBytesWritten != nBytesToWrite)) ? APE_ERROR_IO_WRITE : APE_ERROR_SUCCESS;
}

int CStdLibFileIO::Seek(int64 nPosition, SeekMethod nMethod)
{
    int nOrigin = 0;
    if (nMethod == SeekFileBegin)
        nOrigin = SEEK_SET;
    else if (nMethod == SeekFileEnd)
    {
        nOrigin = SEEK_END;
        nPosition = -abs(nPosition);
    }
    else if (nMethod == SeekFileCurrent)
        nOrigin = SEEK_CUR;
#ifdef PLATFORM_ANDROID
    return fseek(m_pFile, nPosition, nOrigin);
#elif !defined(PLATFORM_WINDOWS)
    return fseeko(m_pFile, nPosition, nOrigin);
#else
    return _fseeki64(m_pFile, nPosition, nOrigin);
#endif
}

int CStdLibFileIO::SetEOF()
{
#ifdef PLATFORM_WINDOWS
    return _chsize_s(GetHandle(), GetPosition());
#else
    return ftruncate(GetHandle(), GetPosition());
#endif
}

int64 CStdLibFileIO::GetPosition()
{
#ifdef PLATFORM_ANDROID
    return ftell(m_pFile);
#elif !defined(PLATFORM_WINDOWS)
    return ftello(m_pFile);
#else
    return _ftelli64(m_pFile);
#endif
}

int64 CStdLibFileIO::GetSize()
{
    if (m_bPipe)
        return APE_FILE_SIZE_UNDEFINED;
    int64 nCurrentPosition = GetPosition();
    Seek(0, SeekFileEnd);
    int64 nLength = GetPosition();
    Seek(nCurrentPosition, SeekFileBegin);
    return nLength;
}

int CStdLibFileIO::Create(const str_utfn * pName)
{
    Close();

    if (wcslen(pName) >= MAX_PATH)
        return APE_ERROR_UNDEFINED;

    if (0 == wcscmp(pName, L"-") || 0 == wcscmp(pName, L"/dev/stdout"))
    {
        m_pFile = SETBINARY_OUT(stdout);
        m_bReadOnly = false;                            // WriteOnly
    }
    else
    {
        CSmartPtr<char> spFilenameUTF8((char *) CAPECharacterHelper::GetUTF8FromUTFN(pName), true);
        // NOTE: on Mac OSX (BSD Unix), we MUST have "w+b" if we want to read & write, with other systems "wb" seems to be fine
        #ifdef PLATFORM_WINDOWS
            fopen_s(&m_pFile, spFilenameUTF8, "w+be");                  // Read/Write
        #else
            m_pFile = fopen(spFilenameUTF8, "w+be");                  // Read/Write
        #endif
        m_bReadOnly = false;
    }

    if (!m_pFile)
        return APE_ERROR_UNDEFINED;

    m_spFileName.AllocateArray(static_cast<int>(wcslen(pName)) + 1);
    memcpy(m_spFileName.GetPtr(), pName, (wcslen(pName) + 1) * sizeof(str_utfn));

    return APE_ERROR_SUCCESS;
}

int CStdLibFileIO::Delete()
{
    Close();
    CSmartPtr<char> spFilenameUTF8((char *) CAPECharacterHelper::GetUTF8FromUTFN(m_spFileName), true);
    #ifdef PLATFORM_WINDOWS
        return _unlink(spFilenameUTF8);    // 0 success, -1 error
    #else
        return unlink(spFilenameUTF8);    // 0 success, -1 error
    #endif
}

}

#endif // #ifdef IO_USE_STD_LIB_FILE_IO
