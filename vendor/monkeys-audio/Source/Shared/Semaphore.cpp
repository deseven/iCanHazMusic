#include "All.h"
#include "Semaphore.h"

namespace APE
{

CSemaphore::CSemaphore(int count)
{
#ifdef PLATFORM_WINDOWS
    m_hSemaphore = CreateSemaphore(APE_NULL, count, count, APE_NULL);
#else
    m_pMutex = new pthread_mutex_t;
    m_pCondition = new pthread_cond_t;

    m_nCount = count;
    m_nMax = count;

    int nResult = pthread_mutex_init(m_pMutex, APE_NULL);

    if (nResult == 0)
    {
        nResult = pthread_cond_init(m_pCondition, APE_NULL);

        if (nResult != 0)
            pthread_mutex_destroy(m_pMutex);
    }

    if (nResult != 0)
    {
        delete m_pMutex;
        delete m_pCondition;

        m_pMutex = APE_NULL;
        m_pCondition = APE_NULL;
    }
#endif
}

CSemaphore::~CSemaphore()
{
#ifdef PLATFORM_WINDOWS
    if (m_hSemaphore)
        CloseHandle(m_hSemaphore);
#else
    if (m_pMutex)
    {
        pthread_mutex_destroy(m_pMutex);
        pthread_cond_destroy(m_pCondition);

        delete m_pMutex;
        delete m_pCondition;
    }
#endif
}

bool CSemaphore::Wait()
{
#ifdef PLATFORM_WINDOWS
    if (m_hSemaphore && WaitForSingleObject(m_hSemaphore, INFINITE) == WAIT_OBJECT_0)
        return true;
#else
    if (m_pMutex)
    {
        pthread_mutex_lock(m_pMutex);

        while (m_nCount <= 0) pthread_cond_wait(m_pCondition, m_pMutex);

        m_nCount -= 1;

        pthread_mutex_unlock(m_pMutex);

        return true;
    }
#endif

    return false;
}

bool CSemaphore::Post()
{
#ifdef PLATFORM_WINDOWS
    if (m_hSemaphore && ReleaseSemaphore(m_hSemaphore, 1, APE_NULL) == 0)
        return true;
#else
    if (m_pMutex)
    {
        pthread_mutex_lock(m_pMutex);

        if (m_nCount < m_nMax)
        {
            m_nCount += 1;

            pthread_cond_signal(m_pCondition);
            pthread_mutex_unlock(m_pMutex);

            return true;
        }

        pthread_mutex_unlock(m_pMutex);
    }
#endif

    return false;
}

}
