#pragma once

namespace APE
{

enum SeekMethod
{
    SeekFileBegin = 0,
    SeekFileCurrent = 1,
    SeekFileEnd = 2
};

class IAPEIO
{
public:
    // destruction
    virtual ~IAPEIO() { }

    // open / close
    virtual int Open(const str_utfn * pName, bool bOpenReadOnly = false) = 0;
    virtual int Close() = 0;

    // read / write
    virtual int Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead = APE_NULL) = 0;
    virtual int Write(const void * pBuffer, int64 nBytesToWrite, int64 * pBytesWritten = APE_NULL) = 0;

    // seek
    virtual int Seek(int64 nPosition, SeekMethod nMethod) = 0;

    // creation / destruction
    virtual int Create(const str_utfn * pName) = 0;
    virtual int Delete() = 0;

    // other functions
    virtual int SetEOF() = 0;
    virtual unsigned char * GetBuffer(int * pnBufferBytes) = 0;

    // attributes
    virtual int64 GetPosition() = 0;
    virtual int64 GetSize() = 0;
};

}
