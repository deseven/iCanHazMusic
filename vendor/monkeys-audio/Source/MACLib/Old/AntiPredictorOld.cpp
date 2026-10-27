#include "All.h"
#ifdef APE_BACKWARDS_COMPATIBILITY

#include "MACLib.h"
#include "AntiPredictorOld.h"

namespace APE
{

CAntiPredictor * CreateAntiPredictor(intn nCompressionLevel, intn nVersion)
{
    CAntiPredictor * pAntiPredictor = APE_NULL;

    switch (nCompressionLevel)
    {
        case APE_COMPRESSION_LEVEL_FAST:
            if (nVersion < 3320)
            {
                pAntiPredictor = new CAntiPredictorFast0000To3320;
            }
            else
            {
                pAntiPredictor = new CAntiPredictorFast3320To3930;
            }
            break;

        case APE_COMPRESSION_LEVEL_NORMAL:
            if (nVersion < 3320)
            {
                pAntiPredictor = new CAntiPredictorNormal0000To3320;
            }
            else if (nVersion < 3800)
            {
                pAntiPredictor = new CAntiPredictorNormal3320To3800;
            }
            else
            {
                pAntiPredictor = new CAntiPredictorNormal3800To3929;
            }
            break;

        case APE_COMPRESSION_LEVEL_HIGH:
            if (nVersion < 3320)
            {
                pAntiPredictor = new CAntiPredictorHigh0000To3320;
            }
            else if (nVersion < 3600)
            {
                pAntiPredictor = new CAntiPredictorHigh3320To3600;
            }
            else if (nVersion < 3700)
            {
                pAntiPredictor = new CAntiPredictorHigh3600To3700;
            }
            else if (nVersion < 3800)
            {
                pAntiPredictor = new CAntiPredictorHigh3700To3800;
            }
            else
            {
                pAntiPredictor = new CAntiPredictorHigh3800To3929;
            }
            break;

        case APE_COMPRESSION_LEVEL_EXTRA_HIGH:
            if (nVersion < 3320)
            {
                pAntiPredictor = new CAntiPredictorExtraHigh0000To3320;
            }
            else if (nVersion < 3600)
            {
                pAntiPredictor = new CAntiPredictorExtraHigh3320To3600;
            }
            else if (nVersion < 3700)
            {
                pAntiPredictor = new CAntiPredictorExtraHigh3600To3700;
            }
            else if (nVersion < 3800)
            {
                pAntiPredictor = new CAntiPredictorExtraHigh3700To3800;
            }
            else
            {
                pAntiPredictor = new CAntiPredictorExtraHigh3800To3929;
            }
            break;

        default:
            pAntiPredictor = APE_NULL; // this shouldn't hit, but just to handle all cases we'll put it here
    }

    return pAntiPredictor;
}

CAntiPredictor::CAntiPredictor()
{
}

CAntiPredictor::~CAntiPredictor()
{
}

void CAntiPredictorOffset::AntiPredictOffset(int * pInputArray, int * pOutputArray, int NumberOfElements, int Offset, int DeltaM)
{
    memcpy(pOutputArray, pInputArray, static_cast<size_t>(Offset) * 4);

    int * ip = &pInputArray[Offset];
    int * ipo = &pOutputArray[0];
    int * op = &pOutputArray[Offset];
    int m = 0;

    for (; op < &pOutputArray[NumberOfElements]; ip++, ipo++, op++)
    {
        *op = *ip + ((*ipo * m) >> 12);

        (*ipo ^ *ip) > 0 ? m += DeltaM : m -= DeltaM;
    }
}

int CAntiPredictorExtraHighHelper::ConventionalDotProduct(short *bip, short *bbm, short *pIPAdaptFactor, int op, int nNumberOfIterations)
{
    // dot product
    int nDotProduct = 0;
    const short * pMaxBBM = &bbm[nNumberOfIterations];

    if (op == 0)
    {
        while(bbm < pMaxBBM)
        {
            APE_EXPAND_32_TIMES(nDotProduct += *bip++ * *bbm++;)
        }
    }
    else if (op > 0)
    {
        while(bbm < pMaxBBM)
        {
            APE_EXPAND_32_TIMES(nDotProduct += *bip++ * *bbm; *bbm++ += *pIPAdaptFactor++;)
        }
    }
    else
    {
        while(bbm < pMaxBBM)
        {
            APE_EXPAND_32_TIMES(nDotProduct += *bip++ * *bbm; *bbm++ -= *pIPAdaptFactor++;)
        }
    }

    // use the dot product
    return nDotProduct;
}

}

#endif // #ifdef APE_BACKWARDS_COMPATIBILITY
