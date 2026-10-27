#include "All.h"
#include "BufferIO.h"
#include "GlobalFunctions.h"

namespace APE
{

/**************************************************************************************************
CBufferIO
**************************************************************************************************/
CBufferIO::CBufferIO(IAPEIO * pSource, int nBufferBytes)
{
    m_spSource.Assign(pSource);
    m_nBufferBytes = 0;
    m_nBufferTotalBytes = nBufferBytes;
    m_spBuffer.AllocateArray(m_nBufferTotalBytes);
    m_bReadToBuffer = true;
}

CBufferIO::~CBufferIO()
{
    m_spSource->Close();
    m_spSource.Delete();
}

int CBufferIO::Open(const str_utfn * pName, bool bOpenReadOnly)
{
    return m_spSource->Open(pName, bOpenReadOnly);
}

int CBufferIO::Close()
{
    return m_spSource->Close();
}

int CBufferIO::Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead)
{
    const int nResult = m_spSource->Read(pBuffer, nBytesToRead, pBytesRead);

    if (m_bReadToBuffer && (m_spBuffer != APE_NULL) && (*pBytesRead > 0))
    {
        const int64 nBufferBytes = APE_MIN<int64>(static_cast<int64>(m_nBufferTotalBytes - m_nBufferBytes), *reinterpret_cast<int64 *>(pBytesRead));
        if (nBufferBytes <= 0)
        {
            m_bReadToBuffer = false;
        }
        else
        {
            memcpy(&m_spBuffer[m_nBufferBytes], pBuffer, static_cast<size_t>(nBufferBytes));
            m_nBufferBytes += static_cast<int>(*pBytesRead);
        }
    }

    return nResult;
}

int CBufferIO::Write(const void *, int64, int64 *)
{
    return APE_ERROR_IO_WRITE;
}

int CBufferIO::Seek(int64 nPosition, SeekMethod nMethod)
{
    m_bReadToBuffer = false; // we seeked, so stop buffering

    // perform the seek on the underlying source
    return m_spSource->Seek(nPosition, nMethod);
}

int CBufferIO::SetEOF()
{
    return m_spSource->SetEOF();
}

unsigned char * CBufferIO::GetBuffer(int * pnBufferBytes)
{
    if (*pnBufferBytes > m_nBufferTotalBytes)
        return APE_NULL; // the request exceeded the size we stored, so return NULL
    ASSERT(*pnBufferBytes == m_nBufferBytes);
    *pnBufferBytes = m_nBufferBytes;
    m_bReadToBuffer = false; // no longer needed
    return m_spBuffer;
}

int64 CBufferIO::GetPosition()
{
    if (m_bReadToBuffer)
    {
        // getting the position on a pipe doesn't work, so we need to do this
        return m_nBufferBytes;
    }
    else
    {
        return m_spSource->GetPosition();
    }
}

int64 CBufferIO::GetSize()
{
    return m_spSource->GetSize();
}

int CBufferIO::Create(const str_utfn * pName)
{
    return m_spSource->Create(pName);
}

int CBufferIO::Delete()
{
    return m_spSource->Delete();
}

/**************************************************************************************************
CHeaderIO
**************************************************************************************************/
CHeaderIO::CHeaderIO(IAPEIO * pSource)
{
    m_spSource.Assign(pSource);
    m_nPosition = 0; // start at position zero even though we read the header
    m_nHeaderBytes = 0;
    APE_CLEAR(m_aryHeader);
}

CHeaderIO::~CHeaderIO()
{
    m_spSource->Close();
    m_spSource.Delete();
}

bool CHeaderIO::ReadHeader(BYTE (& aryHeader)[64])
{
    // zero out the entire header object
    APE_CLEAR(aryHeader);

    // read but cap at the file size
    int64 nFileSize = GetSize();
    if ((nFileSize > 64) || (nFileSize == APE_FILE_SIZE_UNDEFINED))
        nFileSize = 64;
    m_nHeaderBytes = nFileSize;
    if (ReadSafe(m_spSource, m_aryHeader, static_cast<int>(m_nHeaderBytes)) != APE_ERROR_SUCCESS)
        return false;

    // copy the header out
    memcpy(aryHeader, m_aryHeader, static_cast<size_t>(m_nHeaderBytes));
    return true;
}

int CHeaderIO::Open(const str_utfn * pName, bool bOpenReadOnly)
{
    return m_spSource->Open(pName, bOpenReadOnly);
}

int CHeaderIO::Close()
{
    return m_spSource->Close();
}

int CHeaderIO::Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead)
{
    // if we're inside the header, just copy out of it for the first part of the read
    int64 nBytesRead = 0;
    int nResult = APE_ERROR_SUCCESS;
    if (m_nPosition < m_nHeaderBytes)
    {
        // read from header
        int64 nBytesFromBuffer = APE_MIN<int64>(m_nHeaderBytes - m_nPosition, nBytesToRead);
        memcpy(pBuffer, &m_aryHeader[m_nPosition], static_cast<size_t>(nBytesFromBuffer));
        char * pBufferChar = reinterpret_cast<char *>(pBuffer);
        int64 nBytesFromReader = nBytesToRead - nBytesFromBuffer;

        // reader
        if (nBytesFromReader > 0)
            nResult = m_spSource->Read(&pBufferChar[nBytesFromBuffer], nBytesFromReader, &nBytesRead);

        // add the number of bytes we read from the buffer
        nBytesRead += nBytesFromBuffer;
    }
    else
    {
        // just pass through to the reader
        nResult = m_spSource->Read(pBuffer, nBytesToRead, &nBytesRead);
    }

    // increment position
    m_nPosition += nBytesRead;

    // set bytes read
    if (pBytesRead != APE_NULL)
        *pBytesRead = nBytesRead;

    // return result
    return nResult;
}

int CHeaderIO::Write(const void *, int64, int64 *)
{
    return APE_ERROR_IO_WRITE;
}

int CHeaderIO::Seek(int64 nPosition, SeekMethod nMethod)
{
    if (nMethod == SeekFileCurrent)
    {
        m_nPosition += nPosition;
        if (m_nPosition > m_nHeaderBytes)
            m_spSource->Seek(m_nPosition, SeekFileBegin);
        return APE_ERROR_SUCCESS;
    }
    else if (nMethod == SeekFileBegin)
    {
        m_nPosition = nPosition;
        if (m_nPosition > m_nHeaderBytes)
            m_spSource->Seek(m_nPosition, SeekFileBegin);
        else
            m_spSource->Seek(m_nHeaderBytes, SeekFileBegin);
        return APE_ERROR_SUCCESS;
    }
    else if (nMethod == SeekFileEnd)
    {
        m_nPosition = GetSize() - abs(nPosition);
        if (m_nPosition > m_nHeaderBytes)
            m_spSource->Seek(m_nPosition, SeekFileBegin);
        else
            m_spSource->Seek(m_nHeaderBytes, SeekFileBegin);
        return APE_ERROR_SUCCESS;
    }

    return APE_ERROR_IO_READ;
}

int CHeaderIO::SetEOF()
{
    return m_spSource->SetEOF();
}

int64 CHeaderIO::GetPosition()
{
    return m_nPosition;
}

int64 CHeaderIO::GetSize()
{
    return m_spSource->GetSize();
}

int CHeaderIO::Create(const str_utfn * pName)
{
    return m_spSource->Create(pName);
}

int CHeaderIO::Delete()
{
    return m_spSource->Delete();
}

}
