#pragma once

namespace APE
{

class CAntiPredictor;

CAntiPredictor * CreateAntiPredictor(intn nCompressionLevel, intn nVersion);

/**************************************************************************************************
Base class for all anti-predictors
**************************************************************************************************/
class CAntiPredictor
{
public:
    CAntiPredictor();
    virtual ~CAntiPredictor();

    virtual void AntiPredict(int *, int *, int) { }
};

/**************************************************************************************************
Offset anti-predictor
**************************************************************************************************/
class CAntiPredictorOffset : public CAntiPredictor
{
public:
    void AntiPredictOffset(int * pInputArray, int * pOutputArray, int NumberOfElements, int Offset, int DeltaM);
};

/**************************************************************************************************
Fast anti-predictor (from original 'fast' mode...updated for version 3.32)
**************************************************************************************************/
class CAntiPredictorFast0000To3320 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
Fast anti-predictor (new 'fast' mode release with version 3.32)
**************************************************************************************************/
class CAntiPredictorFast3320To3930 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
Normal anti-predictor
**************************************************************************************************/
class CAntiPredictorNormal0000To3320 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
Normal anti-predictor
**************************************************************************************************/
class CAntiPredictorNormal3320To3800 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
Normal anti-predictor
**************************************************************************************************/
class CAntiPredictorNormal3800To3929 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
High anti-predictor
**************************************************************************************************/
class CAntiPredictorHigh0000To3320 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
High anti-predictor
**************************************************************************************************/
class CAntiPredictorHigh3320To3600 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
High anti-predictor
**************************************************************************************************/
class CAntiPredictorHigh3600To3700 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
High anti-predictor
**************************************************************************************************/
class CAntiPredictorHigh3700To3800 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
High anti-predictor
**************************************************************************************************/
class CAntiPredictorHigh3800To3929 : public CAntiPredictor
{
public:
    void AntiPredict(int * pInputArray, int * pOutputArray, int NumberOfElements) APE_OVERRIDE;
};

/**************************************************************************************************
Extra high helper
**************************************************************************************************/
class CAntiPredictorExtraHighHelper
{
public:
    int ConventionalDotProduct(short * bip, short * bbm, short * pIPAdaptFactor, int op, int nNumberOfIterations);
};

/**************************************************************************************************
Extra high anti-predictor
**************************************************************************************************/
class CAntiPredictorExtraHigh0000To3320 : public CAntiPredictor
{
public:
    void AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB);

private:
    void AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g, int dm, int nMaxOrder);
};

/**************************************************************************************************
Extra high anti-predictor
**************************************************************************************************/
class CAntiPredictorExtraHigh3320To3600 : public CAntiPredictor
{
public:
    void AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB);

private:
    void AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g, int dm, int nMaxOrder);
};

/**************************************************************************************************
Extra high anti-predictor
**************************************************************************************************/
class CAntiPredictorExtraHigh3600To3700 : public CAntiPredictor
{
public:
    void AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB);

private:
    void AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g1, int64 g2, int nMaxOrder);
};

/**************************************************************************************************
Extra high anti-predictor
**************************************************************************************************/
class CAntiPredictorExtraHigh3700To3800 : public CAntiPredictor
{
public:
    void AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, int Iterations, const int64 * pOffsetValueArrayA, const int64 * pOffsetValueArrayB);

private:
    void AntiPredictorOffset(const int * pInputArray, int * pOutputArray, int nNumberOfElements, int64 g1, int64 g2, int nMaxOrder);
};

/**************************************************************************************************
Extra high anti-predictor
**************************************************************************************************/
class CAntiPredictorExtraHigh3800To3929 : public CAntiPredictor
{
public:
    void AntiPredictCustom(int * pInputArray, int * pOutputArray, int NumberOfElements, intn nVersion);
};

}
