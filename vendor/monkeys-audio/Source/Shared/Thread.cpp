#include "All.h"
#include "Thread.h"

namespace APE
{

CThread::CThread()
{
#ifdef PLATFORM_WINDOWS
    InitializeCriticalSection(&m_hMutex);

    m_hThread = APE_NULL;
#else
    pthread_mutex_init(&m_hMutex, APE_NULL);

    m_pThread = APE_NULL;
#endif
}

CThread::~CThread()
{
    Wait();

#ifdef PLATFORM_WINDOWS
    DeleteCriticalSection(&m_hMutex);
#else
    pthread_mutex_destroy(&m_hMutex);
#endif
}

bool CThread::Start()
{
#ifdef PLATFORM_WINDOWS
    m_hThread = CreateThread(APE_NULL, 0, Caller, this, 0, APE_NULL);
#else
    m_pThread = new pthread_t;

    pthread_create(m_pThread, APE_NULL, Caller, this);
#endif

    return true;
}

bool CThread::Wait()
{
#ifdef PLATFORM_WINDOWS
    EnterCriticalSection(&m_hMutex);

    if (!m_hThread)
    {
        LeaveCriticalSection(&m_hMutex);

        return false;
    }

    HANDLE thread = m_hThread;

    m_hThread = APE_NULL;

    LeaveCriticalSection(&m_hMutex);
    WaitForSingleObject(thread, INFINITE);

    CloseHandle(thread);
#else
    pthread_mutex_lock(&m_hMutex);

    if (!m_pThread)
    {
        pthread_mutex_unlock(&m_hMutex);

        return false;
    }

    pthread_t *thread = m_pThread;

    m_pThread = APE_NULL;

    pthread_mutex_unlock(&m_hMutex);
    pthread_join(*thread, APE_NULL);

    delete thread;
#endif

    return true;
}

#ifdef PLATFORM_WINDOWS
DWORD WINAPI CThread::Caller(LPVOID param)
{
    CThread * thread = reinterpret_cast<CThread *>(param);

    thread->Run();

    return 0;
}
#else
void * CThread::Caller(void * param)
{
    CThread * thread = reinterpret_cast<CThread *>(param);

    thread->Run();

    return APE_NULL;
}
#endif

}
