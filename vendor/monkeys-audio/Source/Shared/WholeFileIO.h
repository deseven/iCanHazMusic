#pragma once

#include "IAPEIO.h"

namespace APE
{

class CWholeFileIO : public IAPEIO
{
public:
    // construction
    static CWholeFileIO * CreateWholeFileIO(IAPEIO * pSource, int64 nSize);

    // construction / destruction
    CWholeFileIO(IAPEIO * pSource, unsigned char * pBuffer, int64 nFileBytes);
    ~CWholeFileIO() APE_OVERRIDE;

    // open / close
    int Open(const str_utfn * pName, bool bOpenReadOnly = false) APE_OVERRIDE;
    int Close() APE_OVERRIDE;

    // read / write
    int Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead = APE_NULL) APE_OVERRIDE;
    int Write(const void * pBuffer, int64 nBytesToWrite, int64 * pBytesWritten = APE_NULL) APE_OVERRIDE;

    // seek
    int Seek(int64 nPosition, SeekMethod nMethod) APE_OVERRIDE;

    // other functions
    int SetEOF() APE_OVERRIDE;
    unsigned char * GetBuffer(int *) APE_OVERRIDE { return APE_NULL; }

    // creation / destruction
    int Create(const str_utfn * pName) APE_OVERRIDE;
    int Delete() APE_OVERRIDE;

    // attributes
    int64 GetPosition() APE_OVERRIDE;
    int64 GetSize() APE_OVERRIDE;

private:
    CSmartPtr<IAPEIO> m_spSource;
    CSmartPtr<unsigned char> m_spWholeFile;
    CSmartPtr<unsigned char> m_spBuffer;
    int64 m_nWholeFilePointer;
    int64 m_nWholeFileSize;
};

}
