#include "All.h"
#include "CircleBuffer.h"
#include "CRC.h"
#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    #include "GlobalFunctions.h"
#endif

namespace APE
{

CCircleBuffer::CCircleBuffer()
{
    m_nTotal = 0;
    m_nHead = 0;
    m_nTail = 0;
    m_nEndCap = 0;
    m_nMaxDirectWriteBytes = 0;
}

CCircleBuffer::~CCircleBuffer()
{
    m_spBuffer.Delete();
}

void CCircleBuffer::CreateBuffer(uint32 nBytes, uint32 nMaxDirectWriteBytes)
{
    m_spBuffer.Delete();

    m_nMaxDirectWriteBytes = nMaxDirectWriteBytes;
    m_nTotal = nBytes + 1 + nMaxDirectWriteBytes;
    m_spBuffer.AllocateArray(m_nTotal);
    m_nHead = 0;
    m_nTail = 0;
    m_nEndCap = m_nTotal;
}

uint32 CCircleBuffer::MaxAdd() const
{
    const uint32 nMaxAdd = (m_nTail >= m_nHead) ? (m_nTotal - 1 - m_nMaxDirectWriteBytes) - (m_nTail - m_nHead) : m_nHead - m_nTail - 1;
    return nMaxAdd;
}

uint32 CCircleBuffer::MaxGet() const
{
    return (m_nTail >= m_nHead) ? m_nTail - m_nHead : (m_nEndCap - m_nHead) + m_nTail;
}

uint32 CCircleBuffer::UpdateCRC(uint32 nCRC, uint32 nBytesPerBlock, uint32 nBlocks)
{
    const uint32 nFrontBytes = APE_MIN(m_nTail, nBlocks * nBytesPerBlock);
    const uint32 nHeadBytes = nBlocks * nBytesPerBlock - nFrontBytes;

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    SwitchBufferBytes(&m_spBuffer[m_nEndCap - nHeadBytes], nBytesPerBlock, nHeadBytes / nBytesPerBlock);
    SwitchBufferBytes(&m_spBuffer[m_nTail - nFrontBytes], nBytesPerBlock, nFrontBytes / nBytesPerBlock);
#endif

    if (nHeadBytes > 0)
        nCRC = CRC_update(nCRC, &m_spBuffer[m_nEndCap - nHeadBytes], static_cast<int>(nHeadBytes));

    nCRC = CRC_update(nCRC, &m_spBuffer[m_nTail - nFrontBytes], static_cast<int>(nFrontBytes));

#if APE_BYTE_ORDER == APE_BIG_ENDIAN
    SwitchBufferBytes(&m_spBuffer[m_nEndCap - nHeadBytes], nBytesPerBlock, nHeadBytes / nBytesPerBlock);
    SwitchBufferBytes(&m_spBuffer[m_nTail - nFrontBytes], nBytesPerBlock, nFrontBytes / nBytesPerBlock);
#endif

    return nCRC;
}

uint32 CCircleBuffer::Get(unsigned char * pBuffer, uint32 nBytes)
{
    uint32 nTotalGetBytes = 0;

    if (pBuffer != APE_NULL && nBytes > 0)
    {
        uint32 nHeadBytes = APE_MIN(m_nEndCap - m_nHead, nBytes);
        const uint32 nFrontBytes = nBytes - nHeadBytes;

        memcpy(&pBuffer[0], &m_spBuffer[m_nHead], static_cast<size_t>(nHeadBytes));
        nTotalGetBytes = nHeadBytes;

        if (nFrontBytes > 0)
        {
            memcpy(&pBuffer[nHeadBytes], &m_spBuffer[0], static_cast<size_t>(nFrontBytes));
            nTotalGetBytes += nFrontBytes;
        }

        RemoveHead(nBytes);
    }

    return nTotalGetBytes;
}

void CCircleBuffer::Empty()
{
    m_nHead = 0;
    m_nTail = 0;
    m_nEndCap = m_nTotal;
}

uint32 CCircleBuffer::RemoveHead(uint32 nBytes)
{
    nBytes = APE_MIN(MaxGet(), nBytes);
    m_nHead += nBytes;
    if (m_nHead >= m_nEndCap)
        m_nHead -= m_nEndCap;
    return nBytes;
}

uint32 CCircleBuffer::RemoveTail(uint32 nBytes)
{
    nBytes = APE_MIN(MaxGet(), nBytes);
    if (m_nTail < nBytes)
        m_nTail += m_nEndCap;
    m_nTail -= nBytes;
    return nBytes;
}

}
