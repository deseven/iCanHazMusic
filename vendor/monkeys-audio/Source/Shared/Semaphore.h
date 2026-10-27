#pragma once

#ifdef PLATFORM_WINDOWS
#include <Windows.h>
#include <winnt.h>
#else
#include <pthread.h>
#endif

namespace APE
{

class CSemaphore
{
public:
    CSemaphore(int count);
    ~CSemaphore();

    bool Wait();
    bool Post();

protected:
#ifdef PLATFORM_WINDOWS
    HANDLE m_hSemaphore;
#else
    pthread_mutex_t *m_pMutex;
    pthread_cond_t *m_pCondition;

    int m_nCount;
    int m_nMax;
#endif
};

}
