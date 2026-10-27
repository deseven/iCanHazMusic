#include "All.h"
#include "MemoryIO.h"

namespace APE
{

CMemoryIO::CMemoryIO(unsigned char * pBuffer, int nBufferBytes)
{
    m_pBuffer = pBuffer;
    m_nBufferBytes = nBufferBytes;

    m_nPosition = 0;
}

CMemoryIO::~CMemoryIO()
{
}

int CMemoryIO::Open(const str_utfn * pName, bool bOpenReadOnly)
{
    (void) pName;
    (void) bOpenReadOnly;

    return APE_ERROR_UNDEFINED;
}

int CMemoryIO::Close()
{
    return APE_ERROR_UNDEFINED;
}

int CMemoryIO::Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead)
{
    int64 nBytesRead = APE_MIN(nBytesToRead, static_cast<int64>(m_nBufferBytes - m_nPosition));
    memcpy(pBuffer, m_pBuffer + m_nPosition, static_cast<size_t>(nBytesRead));
    m_nPosition += nBytesRead;
    if (pBytesRead != APE_NULL)
        *pBytesRead = nBytesRead;
    return APE_ERROR_SUCCESS;
}

int CMemoryIO::Write(const void * pBuffer, int64 nBytesToWrite, int64 * pBytesWritten)
{
    int64 nBytesWritten = APE_MIN(nBytesToWrite, static_cast<int64>(m_nBufferBytes - m_nPosition));
    memcpy(m_pBuffer + m_nPosition, pBuffer, static_cast<size_t>(nBytesWritten));
    m_nPosition += nBytesWritten;
    if (pBytesWritten != APE_NULL)
        *pBytesWritten = nBytesWritten;
    return APE_ERROR_SUCCESS;
}

int CMemoryIO::Seek(int64 nPosition, SeekMethod nMethod)
{
    switch (nMethod)
    {
    case SeekFileBegin:
        if (nPosition > m_nBufferBytes)
            return APE_ERROR_UNDEFINED;
        m_nPosition = static_cast<int>(nPosition);
        break;
    case SeekFileEnd:
        if (nPosition > m_nBufferBytes)
            return APE_ERROR_UNDEFINED;
        m_nPosition = static_cast<int>(m_nBufferBytes - nPosition);
        break;
    case SeekFileCurrent:
        if (m_nPosition + nPosition < 0 || m_nPosition + nPosition > m_nBufferBytes)
            return APE_ERROR_UNDEFINED;
        m_nPosition = static_cast<int>(m_nPosition + nPosition);
        break;
    }

    return APE_ERROR_SUCCESS;
}

int CMemoryIO::SetEOF()
{
    return APE_ERROR_UNDEFINED;
}

unsigned char * CMemoryIO::GetBuffer(int * pnBufferBytes)
{
    if (*pnBufferBytes >  m_nBufferBytes)
        return APE_NULL; // the request exceeded the size we stored, so return NULL
    ASSERT(*pnBufferBytes == m_nBufferBytes);
    *pnBufferBytes = m_nBufferBytes;
    return m_pBuffer;
}

int64 CMemoryIO::GetPosition()
{
    return m_nPosition;
}

int64 CMemoryIO::GetSize()
{
    return m_nBufferBytes;
}

int CMemoryIO::Create(const str_utfn *)
{
    return APE_ERROR_UNDEFINED;
}

int CMemoryIO::Delete()
{
    return APE_ERROR_UNDEFINED;
}

}
