#pragma once

namespace APE
{

/**************************************************************************************************
IPredictorCompress - the interface for compressing (predicting) data
**************************************************************************************************/
class IPredictorCompress
{
public:
    virtual ~IPredictorCompress() { }

    virtual int64 CompressValue(int nA, int nB = 0) = 0;
    virtual int Flush() = 0;
};

/**************************************************************************************************
IPredictorDecompress - the interface for decompressing (un-predicting) data
**************************************************************************************************/
class IPredictorDecompress
{
public:
    virtual ~IPredictorDecompress() { }

    virtual int DecompressValue(int64 nA, int64 nB = 0) = 0;
    virtual int Flush() = 0;
};

}
