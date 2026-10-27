#include "All.h"
#include "FloatTransform.h"

using namespace APE;

/**************************************************************************************************
CFloatTransform
**************************************************************************************************/
/*static*/ void CFloatTransform::Process(uint32 * pBuffer, int64 nSamples)
{
    for (int64 n = 0; n < nSamples; n++)
    {
        const uint32 sampleIn = pBuffer[n];
        uint32 sampleOut = 0;

        sampleOut |= sampleIn & 0xC3FFFFFF;
        sampleOut |= ~(sampleIn & 0x3C000000) ^ 0xC3FFFFFF;

        if (sampleOut & 0x80000000)
            sampleOut = ~sampleOut | 0x80000000;

        pBuffer[n] = sampleOut;
    }
}
