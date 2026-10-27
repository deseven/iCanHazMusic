#include "All.h"
#ifdef APE_BACKWARDS_COMPATIBILITY

#include "AntiPredictorOld.h"

namespace APE
{

/**************************************************************************************************
Extra high 0000 to 3320 implementation
**************************************************************************************************/
void CAntiPredictorExtraHigh0000To3320::AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB)
{
    for (int z = Iterations; z >= 0; z--)
    {
        AntiPredictorOffset(pInputArray, pOutputArray, NumberOfElements, static_cast<int64>(pOffsetValueArrayB[z]), -1, 64);
        AntiPredictorOffset(pOutputArray, pInputArray, NumberOfElements, static_cast<int64>(pOffsetValueArrayA[z]), 1, 64);
    }

    CAntiPredictorHigh0000To3320 AntiPredictor;
    AntiPredictor.AntiPredict(pInputArray, pOutputArray, NumberOfElements);
}

void CAntiPredictorExtraHigh0000To3320::AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g, int dm, int nMaxOrder)
{
    int q;

    if ((g==0) || (nNumberOfElements <= nMaxOrder))
    {
        memcpy(pOutputArray, pInputArray, static_cast<size_t>(nNumberOfElements) * 4);
        return;
    }

    memcpy(pOutputArray, pInputArray, static_cast<size_t>(nMaxOrder) * 4);

    if (dm > 0)
    {
        for (q = nMaxOrder; q < nNumberOfElements; q++)
        {
            pOutputArray[q] = pInputArray[q] + (pOutputArray[q - g] >> 3);
        }
    }
    else
    {
        for (q = nMaxOrder; q < nNumberOfElements; q++)
        {
            pOutputArray[q] = pInputArray[q] - (pOutputArray[q - g] >> 3);
        }
    }
}


/**************************************************************************************************
Extra high 3320 to 3600 implementation
**************************************************************************************************/
void CAntiPredictorExtraHigh3320To3600::AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB)
{
    for (int z = Iterations; z >= 0; z--)
    {
        AntiPredictorOffset(pInputArray, pOutputArray, NumberOfElements, static_cast<int64>(pOffsetValueArrayB[z]), -1, 32);
        AntiPredictorOffset(pOutputArray, pInputArray, NumberOfElements, static_cast<int64>(pOffsetValueArrayA[z]), 1, 32);
    }

    CAntiPredictorHigh0000To3320 AntiPredictor;
    AntiPredictor.AntiPredict(pInputArray, pOutputArray, NumberOfElements);
}


void CAntiPredictorExtraHigh3320To3600::AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g, int dm, int nMaxOrder)
{
    int q;

    if ((g==0) || (nNumberOfElements <= nMaxOrder))
    {
        memcpy(pOutputArray, pInputArray, static_cast<size_t>(nNumberOfElements) * 4);
        return;
    }

    memcpy(pOutputArray, pInputArray, static_cast<size_t>(nMaxOrder) * 4);

    int m = 512;

    if (dm > 0)
    {
        for (q = nMaxOrder; q < nNumberOfElements; q++)
        {
            pOutputArray[q] = pInputArray[q] + ((pOutputArray[q - g] * m) >> 12);
            (pInputArray[q] ^ pOutputArray[q - g]) > 0 ? m += 8 : m -= 8;
        }
    }
    else
    {
        for (q = nMaxOrder; q < nNumberOfElements; q++)
        {
            pOutputArray[q] = pInputArray[q] - ((pOutputArray[q - g] * m) >> 12);
            (pInputArray[q] ^ pOutputArray[q - g]) > 0 ? m -= 8 : m += 8;
        }
    }
}

/**************************************************************************************************
Extra high 3600 to 3700 implementation
**************************************************************************************************/
void CAntiPredictorExtraHigh3600To3700::AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB)
{
    for (int z = Iterations; z >= 0; )
    {
        AntiPredictorOffset(pInputArray, pOutputArray, NumberOfElements, pOffsetValueArrayA[z], pOffsetValueArrayB[z], 64);
        z--;

        if (z >= 0)
        {
            AntiPredictorOffset(pOutputArray, pInputArray, NumberOfElements, pOffsetValueArrayA[z], pOffsetValueArrayB[z], 64);
            z--;
        }
        else
        {
            memcpy(pInputArray, pOutputArray, static_cast<size_t>(NumberOfElements) * 4);
            break;
        }
    }

    CAntiPredictorHigh3600To3700 AntiPredictor;
    AntiPredictor.AntiPredict(pInputArray, pOutputArray, NumberOfElements);
}

void CAntiPredictorExtraHigh3600To3700::AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g1, int64 g2, int nMaxOrder)
{
    int q;

    if ((g1==0) || (g2==0) || (nNumberOfElements <= nMaxOrder))
    {
        memcpy(pOutputArray, pInputArray, static_cast<size_t>(nNumberOfElements) * 4);
        return;
    }

    memcpy(pOutputArray, pInputArray, static_cast<size_t>(nMaxOrder) * 4);

    int m = 64;
    int m2 = 64;

    for (q = nMaxOrder; q < nNumberOfElements; q++)
    {
        pOutputArray[q] = pInputArray[q] + ((pOutputArray[q - g1] * m) >> 9) - ((pOutputArray[q - g2] * m2) >> 9);
        (pInputArray[q] ^ pOutputArray[q - g1]) > 0 ? m++ : m--;
        (pInputArray[q] ^ pOutputArray[q - g2]) > 0 ? m2-- : m2++;
    }
}

/**************************************************************************************************
Extra high 3700 to 3800 implementation
**************************************************************************************************/
void CAntiPredictorExtraHigh3700To3800::AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB)
{
    for (int z = Iterations; z >= 0; )
    {
        AntiPredictorOffset(pInputArray, pOutputArray, NumberOfElements, pOffsetValueArrayA[z], pOffsetValueArrayB[z], 64);
        z--;

        if (z >= 0)
        {
            AntiPredictorOffset(pOutputArray, pInputArray, NumberOfElements, pOffsetValueArrayA[z], pOffsetValueArrayB[z], 64);
            z--;
        }
        else
        {
            memcpy(pInputArray, pOutputArray, static_cast<size_t>(NumberOfElements) * 4);
            break;
        }
    }

    CAntiPredictorHigh3700To3800 AntiPredictor;
    AntiPredictor.AntiPredict(pInputArray, pOutputArray, NumberOfElements);

}

void CAntiPredictorExtraHigh3700To3800::AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g1, int64 g2, int nMaxOrder)
{
    int q;

    if ((g1==0) || (g2==0) || (nNumberOfElements <= nMaxOrder))
    {
        memcpy(pOutputArray, pInputArray, static_cast<size_t>(nNumberOfElements) * 4);
        return;
    }

    memcpy(pOutputArray, pInputArray, static_cast<size_t>(nMaxOrder) * 4);

    int m = 64;
    int m2 = 64;

    for (q = nMaxOrder; q < nNumberOfElements; q++)
    {
        pOutputArray[q] = pInputArray[q] + ((pOutputArray[q - g1] * m) >> 9) - ((pOutputArray[q - g2] * m2) >> 9);
        (pInputArray[q] ^ pOutputArray[q - g1]) > 0 ? m++ : m--;
        (pInputArray[q] ^ pOutputArray[q - g2]) > 0 ? m2-- : m2++;
    }
}

/**************************************************************************************************
Extra high 3800 to 3930
**************************************************************************************************/
void CAntiPredictorExtraHigh3800To3929::AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, intn nVersion)
{
    const int nFilterStageElements = (nVersion < 3830) ? 128 : 256;
    const int nFilterStageShift = (nVersion < 3830) ? 11 : 12;
    const int nMaxElements = (nVersion < 3830) ? 134 : 262;
    const int nFirstElement = (nVersion < 3830) ? 128 : 256;
    const int nStageCShift = (nVersion < 3830) ? 10 : 11;

    // short frame handling
    if (NumberOfElements < nMaxElements)
    {
        memcpy(pOutputArray, pInputArray, static_cast<size_t>(NumberOfElements) * 4);
        return;
    }

    // make the first five samples identical in both arrays
    memcpy(pOutputArray, pInputArray, static_cast<size_t>(nFirstElement) * 4);

    // variable declares and initializations
    short bm[256]; APE_CLEAR(bm);
    int m2 = 64, m3 = 115, m4 = 64, m5 = 740, m6 = 0;
    int p4 = pInputArray[nFirstElement - 1];
    int p3 = (pInputArray[nFirstElement - 1] - pInputArray[nFirstElement - 2]) << 1;
    int p2 = pInputArray[nFirstElement - 1] + ((pInputArray[nFirstElement - 3] - pInputArray[nFirstElement - 2]) << 3);
    int * op = &pOutputArray[nFirstElement];
    int * ip = &pInputArray[nFirstElement];
    int IPP2 = ip[-2];
    int p7 = 2 * ip[-1] - ip[-2];
    int opp = op[-1];
    int Original;
    CAntiPredictorExtraHighHelper Helper;

    // undo the initial prediction stuff
    int q; // loop variable
    for (q = 1; q < nFirstElement; q++)
    {
        pOutputArray[q] += pOutputArray[q - 1];
    }

    // pump the primary loop
    short * IPAdaptFactor = static_cast<short *>(calloc(static_cast<size_t>(NumberOfElements), 2));
    short * IPShort = static_cast<short *>(calloc(static_cast<size_t>(NumberOfElements), 2));
    for (q = 0; q < nFirstElement; q++)
    {
        IPAdaptFactor[q] = static_cast<short>(((pInputArray[q] >> 30) & 2) - 1);
        IPShort[q] = static_cast<short>(pInputArray[q]);
    }

    int FM[9]; APE_CLEAR(FM);
    int FP[9]; APE_CLEAR(FP);

    for (q = nFirstElement; op < &pOutputArray[NumberOfElements]; op++, ip++, q++)
    {
        if (nVersion >= 3830)
        {
            int * pFP = &FP[8];
            int * pFM = &FM[8];
            int nDotProduct = 0;
            FP[0] = ip[0];

            if (FP[0] == 0)
            {
                APE_EXPAND_8_TIMES(nDotProduct += *pFP * *pFM--; (*pFP = *(pFP - 1), --pFP);)
            }
            else if (FP[0] > 0)
            {
                APE_EXPAND_8_TIMES(nDotProduct += *pFP * *pFM; *pFM-- += ((*pFP >> 30) & 2) - 1; (*pFP = *(pFP - 1), --pFP);)
            }
            else
            {
                APE_EXPAND_8_TIMES(nDotProduct += *pFP * *pFM; *pFM-- -= ((*pFP >> 30) & 2) - 1; (*pFP = *(pFP - 1), --pFP);)

            }

            *ip -= nDotProduct >> 9;
        }

        Original = *ip;

        IPShort[q] = static_cast<short>(*ip);
        IPAdaptFactor[q] = static_cast<short>(((ip[0] >> 30) & 2) - 1);

        *ip -= (Helper.ConventionalDotProduct(&IPShort[q-nFirstElement], &bm[0], &IPAdaptFactor[q-nFirstElement], Original, nFilterStageElements) >> nFilterStageShift);

        IPShort[q] = static_cast<short>(*ip);
        IPAdaptFactor[q] = static_cast<short>(((ip[0] >> 30) & 2) - 1);

        /////////////////////////////////////////////
        *op = *ip + (((p2 * m2) + (p3 * m3) + (p4 * m4)) >> 11);

        if (*ip > 0)
        {
            m2 -= ((p2 >> 30) & 2) - 1;
            m3 -= ((p3 >> 28) & 8) - 4;
            m4 -= ((p4 >> 28) & 8) - 4;
        }
        else if (*ip < 0)
        {
            m2 += ((p2 >> 30) & 2) - 1;
            m3 += ((p3 >> 28) & 8) - 4;
            m4 += ((p4 >> 28) & 8) - 4;
        }


        p2 = *op + ((IPP2 - p4) << 3);
        p3 = (*op - p4) << 1;
        IPP2 = p4;
        p4 = *op;

        /////////////////////////////////////////////
        *op += (((p7 * m5) - (opp * m6)) >> nStageCShift);

        if (p4 > 0)
        {
            m5 -= ((p7 >> 29) & 4) - 2;
            m6 += ((opp >> 30) & 2) - 1;
        }
        else if (p4 < 0)
        {
            m5 += ((p7 >> 29) & 4) - 2;
            m6 -= ((opp >> 30) & 2) - 1;
        }

        p7 = 2 * *op - opp;
        opp = *op;

        /////////////////////////////////////////////
        *op += ((op[-1] * 31) >> 5);
    }

    free(IPAdaptFactor);
    free(IPShort);
}

}

#endif // #ifdef APE_BACKWARDS_COMPATIBILITY
