#pragma once

#ifdef PLATFORM_WINDOWS
#include <Windows.h>
#include <winnt.h>
#else
#include <pthread.h>
#endif

namespace APE
{

class CThread
{
public:
    CThread();
    virtual ~CThread();

    bool Start();
    bool Wait();

protected:
    virtual void Run() = 0;

#ifdef PLATFORM_WINDOWS
    CRITICAL_SECTION m_hMutex;

    HANDLE m_hThread;
#else
    pthread_mutex_t m_hMutex;

    pthread_t * m_pThread;
#endif

private:
#ifdef PLATFORM_WINDOWS
    static DWORD WINAPI Caller(LPVOID);
#else
    static void * Caller(void *);
#endif
};

}
