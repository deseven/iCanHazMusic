#pragma once

#include "IAPEIO.h"

namespace APE
{

/**************************************************************************************************
CBufferIO
**************************************************************************************************/
class CBufferIO : public IAPEIO
{
public:
    // construction / destruction
    CBufferIO(IAPEIO * pSource, int nBufferBytes);
    ~CBufferIO() APE_OVERRIDE;

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
    unsigned char * GetBuffer(int * pnBufferBytes) APE_OVERRIDE;

    // creation / destruction
    int Create(const str_utfn * pName) APE_OVERRIDE;
    int Delete() APE_OVERRIDE;

    // attributes
    int64 GetPosition() APE_OVERRIDE;
    int64 GetSize() APE_OVERRIDE;

private:
    CSmartPtr<IAPEIO> m_spSource;
    CSmartPtr<unsigned char> m_spBuffer;
    int m_nBufferBytes;
    int m_nBufferTotalBytes;
    bool m_bReadToBuffer;
};

/**************************************************************************************************
CHeaderIO
**************************************************************************************************/
class CHeaderIO : public IAPEIO
{
public:
    // construction / destruction
    CHeaderIO(IAPEIO * pSource);
    ~CHeaderIO() APE_OVERRIDE;

    // read the header
    bool ReadHeader(BYTE (& aryHeader)[64]);

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
    unsigned char * GetBuffer(int *)  APE_OVERRIDE { return APE_NULL; }

    // creation / destruction
    int Create(const str_utfn * pName) APE_OVERRIDE;
    int Delete() APE_OVERRIDE;

    // attributes
    int64 GetPosition() APE_OVERRIDE;
    int64 GetSize() APE_OVERRIDE;

private:
    CSmartPtr<IAPEIO> m_spSource;
    int64 m_nHeaderBytes;
    BYTE m_aryHeader[64];
    int64 m_nPosition;
};

}
