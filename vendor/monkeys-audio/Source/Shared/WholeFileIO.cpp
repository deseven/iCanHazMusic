#include "All.h"
#include "WholeFileIO.h"

namespace APE
{

CWholeFileIO * CWholeFileIO::CreateWholeFileIO(IAPEIO * pSource, int64 nSize)
{
    // the size should be correct
    ASSERT(nSize == pSource->GetSize());

    int nResult = APE_ERROR_SUCCESS;
    CWholeFileIO * pIO = APE_NULL;

    // make sure we're at the head of the file
    pSource->Seek(0, SeekFileBegin);

    // the the size as 32-bit
    const uint32 n32BitSize = static_cast<uint32>(nSize); // we established it will fit above

    if (nSize == APE_FILE_SIZE_UNDEFINED)
    {
        // simply read until we're at the EOF
        // we read in 64MB chunks, and grow by 64MB and after the final read there's a little extra at the end that's just filled with garbage and not used by the CWholeFileIO object
        int64 nBytes = 0;

        // keeping this constant was tested by a user and performed the best
        // these were his results encoding a single big file from a pipe:
        // 2x : 45.5s (nGrowBytes *= 2)
        // 1m : 68.2s
        // 16m : 22.6s
        // 64m : 21.8s
        const int64 nGrowBytes = 64 * APE_BYTES_IN_MEGABYTE;

        // allocate the first buffer then start the read loop
        unsigned char * pBuffer = new unsigned char [static_cast<size_t>(nGrowBytes)];
        int64 nBytesRead = 0;
        while ((pBuffer != APE_NULL) && (pSource->Read(&pBuffer[nBytes], nGrowBytes, &nBytesRead) == APE_ERROR_SUCCESS))
        {
            // increment the position
            nBytes += nBytesRead;

            // check for the end of file
            if (nBytesRead < nGrowBytes)
            {
                // we're at the end of the file, so just stop reading
                break;
            }
            else
            {
                // make a new buffer that contains the new data and read again
                unsigned char * pNewBuffer = new unsigned char [static_cast<size_t>(nBytes + nGrowBytes)];
                if (pNewBuffer != APE_NULL)
                {
                    // copy old buffer
                    memcpy(pNewBuffer, pBuffer, static_cast<size_t>(nBytes));

                    // move new buffer into the buffer pointer
                    delete [] pBuffer;
                    pBuffer = pNewBuffer;
                }
                else
                {
                    // just release the buffer and stop reading (since allocation failed)
                    APE_SAFE_ARRAY_DELETE(pBuffer)
                }
            }
        }

        // create IO object
        if (pBuffer != APE_NULL)
            pIO = new CWholeFileIO(pSource, pBuffer, nBytes);

        // don't delete pBuffer since it's now owned by the file I/O object
    }
    else if (nSize == n32BitSize)
    {
        // create a buffer
        CSmartPtr<unsigned char> spWholeFile;
        try
        {
            spWholeFile.AllocateArray(n32BitSize);
            //spWholeFile.Assign(new unsigned char [0x7FFFFFFF], true); // test for allocating a huge size
        }
        catch (...)
        {
            // if we catch the whole file should not have been created
            // we'll delete it just to be safe
            spWholeFile.Delete();
        }

        if (spWholeFile != APE_NULL)
        {
            // read
            int64 nBytesRead = 0;
            nResult = pSource->Read(spWholeFile, n32BitSize, &nBytesRead);
            if (nBytesRead < n32BitSize)
                nResult = APE_ERROR_IO_READ;

            if (nResult == APE_ERROR_SUCCESS)
            {
                // create IO object
                pIO = new CWholeFileIO(pSource, spWholeFile, nBytesRead);
                spWholeFile.SetDelete(false); // it's now owned by CWholeFileIO
            }
        }
    }

    return pIO;
}

CWholeFileIO::CWholeFileIO(IAPEIO * pSource, unsigned char * pBuffer, int64 nFileBytes)
{
    // store source
    m_spSource.Assign(pSource);

    // create a buffer
    m_spWholeFile.Assign(pBuffer, true);
    m_nWholeFilePointer = 0;
    m_nWholeFileSize = nFileBytes;
}

CWholeFileIO::~CWholeFileIO()
{
    m_spSource->Close();
    m_spSource.Delete();
}

int CWholeFileIO::Open(const str_utfn *, bool)
{
    return APE_ERROR_SUCCESS;
}

int CWholeFileIO::Close()
{
    return m_spSource->Close();
}

int CWholeFileIO::Read(void * pBuffer, int64 nBytesToRead, int64 * pBytesRead)
{
    const int64 nBytesLeft = GetSize() - m_nWholeFilePointer;
    nBytesToRead = APE_MIN(nBytesLeft, nBytesToRead);
    memcpy(pBuffer, &m_spWholeFile[m_nWholeFilePointer], static_cast<size_t>(nBytesToRead));
    m_nWholeFilePointer += nBytesToRead;
    if (pBytesRead != APE_NULL)
        *pBytesRead = nBytesToRead;

    return APE_ERROR_SUCCESS;
}

int CWholeFileIO::Write(const void * , int64, int64 *)
{
    return APE_ERROR_IO_WRITE;
}

int CWholeFileIO::Seek(int64 nPosition, SeekMethod nMethod)
{
    if (nMethod == SeekFileBegin)
    {
        m_nWholeFilePointer = nPosition;
    }
    else if (nMethod == SeekFileCurrent)
    {
        m_nWholeFilePointer += nPosition;
    }
    else if (nMethod == SeekFileEnd)
    {
        m_nWholeFilePointer = GetSize() - abs(nPosition);
    }

    return APE_ERROR_SUCCESS;
}

int CWholeFileIO::SetEOF()
{
    // handle memory buffers
    m_nWholeFileSize = m_nWholeFilePointer;

    // seek in the actual file to where we're at
    m_spSource->Seek(m_nWholeFilePointer, SeekFileBegin);

    // set the EOF in the actual file
    return m_spSource->SetEOF();
}

int64 CWholeFileIO::GetPosition()
{
    return m_nWholeFilePointer;
}

int64 CWholeFileIO::GetSize()
{
    return m_nWholeFileSize;
}

int CWholeFileIO::Create(const str_utfn *)
{
    return APE_ERROR_UNDEFINED;
}

int CWholeFileIO::Delete()
{
    return APE_ERROR_UNDEFINED;
}

}
