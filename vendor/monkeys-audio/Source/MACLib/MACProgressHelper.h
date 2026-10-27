#pragma once

#include "MACLib.h"

namespace APE
{

class IAPEProgressCallback;

class CMACProgressHelper
{
public:
    CMACProgressHelper(int64 nTotalSteps, APE::CAPEProgressCallbackInfo * pProgressCallback);

    void UpdateProgress(int64 nCurrentStep = -1, bool bForceUpdate = false);
    void UpdateProgressComplete();

    int ProcessKillFlag();

private:
    int64 m_nTotalSteps;
    int64 m_nCurrentStep;
    int m_nLastCallbackFiredPercentageDone;
    APE::CAPEProgressCallbackInfo * m_pProgressCallback;
};

}
