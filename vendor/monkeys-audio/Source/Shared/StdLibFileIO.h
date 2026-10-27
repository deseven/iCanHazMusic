#ifdef IO_USE_STD_LIB_FILE_IO

#pragma once

#include "IAPEIO.h"

namespace APE
{

class CStdLibFileIO : public IAPEIO
{
public:
    // construction / destruction
    CStdLibFileIO();
    ~CStdLibFileIO() APE_OVERRIDE;

    // open / close
    int Open(const str_utfn * pName, bool bOpenReadOnly = false);
    int Close();

    // read / write
    int Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead = APE_NULL);
    int Write(const void * pBuffer, int64 nBytesToWrite, int64 * pBytesWritten = APE_NULL);

    // seek
    int Seek(int64 nPosition, SeekMethod nMethod);

    // other functions
    int SetEOF();
    unsigned char * GetBuffer(int *) { return APE_NULL; }

    // creation / destruction
    int Create(const str_utfn * pName);
    int Delete();

    // attributes
    int64 GetPosition();
    int64 GetSize();
    int GetHandle();

private:
    CSmartPtr<str_utfn> m_spFileName;
    bool m_bReadOnly;
    bool m_bPipe;
    FILE * m_pFile;
};

}

#endif // #ifdef IO_USE_STD_LIB_FILE_IO
