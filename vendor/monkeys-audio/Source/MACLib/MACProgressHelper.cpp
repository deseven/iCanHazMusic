#include "All.h"
#include "MACProgressHelper.h"
#include "MACLib.h"

namespace APE
{

CMACProgressHelper::CMACProgressHelper(int64 nTotalSteps, CAPEProgressCallbackInfo * pProgressCallback)
{
    m_pProgressCallback = pProgressCallback;

    m_nTotalSteps = nTotalSteps;
    m_nCurrentStep = 0;
    m_nLastCallbackFiredPercentageDone = 0;

    UpdateProgress(0);
}

void CMACProgressHelper::UpdateProgress(int64 nCurrentStep, bool bForceUpdate)
{
    // update the step
     if (nCurrentStep == -1)
         m_nCurrentStep++;
     else
        m_nCurrentStep = nCurrentStep;

    // figure the percentage done
    const double dPercentageDone = static_cast<double>(m_nCurrentStep) / static_cast<double>(APE_MAX<int64>(m_nTotalSteps, 1));
    int nPercentageDone = static_cast<int>((dPercentageDone * 1000 * 100));
    if (nPercentageDone > 100000) nPercentageDone = 100000;

    // fire the callback
    if (m_pProgressCallback != APE_NULL)
    {
        if (bForceUpdate || (nPercentageDone - m_nLastCallbackFiredPercentageDone) >= 1000)
        {
            if (m_pProgressCallback->m_pCallback != APE_NULL)
                m_pProgressCallback->m_pCallback->Progress(nPercentageDone);
            if (m_pProgressCallback->m_ProgressCallback != APE_NULL)
                m_pProgressCallback->m_ProgressCallback(m_pProgressCallback->m_pCallbackData, nPercentageDone);
            m_nLastCallbackFiredPercentageDone = nPercentageDone;
        }
    }
}

void CMACProgressHelper::UpdateProgressComplete()
{
    UpdateProgress(m_nTotalSteps, true);
}

int CMACProgressHelper::ProcessKillFlag()
{
    if (m_pProgressCallback && m_pProgressCallback->m_pCallback)
    {
        int nKill = m_pProgressCallback->m_pCallback->GetKillFlag();
        while (nKill == APE_KILL_FLAG_PAUSE)
        {
            SLEEP(50);
            nKill = m_pProgressCallback->m_pCallback->GetKillFlag();
        }

        if ((nKill != APE_KILL_FLAG_CONTINUE) && (nKill != APE_KILL_FLAG_PAUSE))
        {
            return APE_ERROR_UNDEFINED;
        }
    }
    else if (m_pProgressCallback && m_pProgressCallback->m_KillCallback)
    {
        int nKill = m_pProgressCallback->m_KillCallback(m_pProgressCallback->m_pCallbackData);
        while (nKill == APE_KILL_FLAG_PAUSE)
        {
            SLEEP(50);
            nKill = m_pProgressCallback->m_KillCallback(m_pProgressCallback->m_pCallbackData);
        }

        if ((nKill != APE_KILL_FLAG_CONTINUE) && (nKill != APE_KILL_FLAG_PAUSE))
        {
            return APE_ERROR_UNDEFINED;
        }
    }

    return APE_ERROR_SUCCESS;
}

}
