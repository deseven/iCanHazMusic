#pragma once

#define APE_TICK_COUNT_TYPE uint64_t

/**************************************************************************************************
CAPETicks - encapsulation of getting a timer for all the platforms
**************************************************************************************************/
class CAPETicks
{
public:
    static inline APE_TICK_COUNT_TYPE GetTicks()
    {
        // read using the platform specific tools
        uint64_t nTicks = 0;
        #if defined(PLATFORM_WINDOWS)
            #if (_WIN32_WINNT < _WIN32_WINNT_VISTA)
                nTicks = GetTickCount();
            #else
                nTicks = GetTickCount64();
            #endif
        #else
            struct timeval t;
            gettimeofday(&t, APE_NULL);
            nTicks = t.tv_sec * 1000000LLU + t.tv_usec;
        #endif
        return nTicks;
    }

    static inline int GetFrequency()
    {
        #if defined(PLATFORM_WINDOWS)
            return 1000;
        #else
            return 1000000;
        #endif
    }
};

/**************************************************************************************************
CAPEDuration - measures duration using a CAPETicks
**************************************************************************************************/
class CAPEDuration
{
public:
    CAPEDuration()
    {
        Reset();
    }
    void Reset()
    {
        m_Ticks = CAPETicks::GetTicks();
    }
    int GetElapsedTicks() const
    {
        return static_cast<int>(CAPETicks::GetTicks() - m_Ticks);
    }
    double GetElapsedSeconds() const
    {
        double dElapsedSeconds = static_cast<double>(GetElapsedTicks()) / static_cast<double>(CAPETicks::GetFrequency());
        return dElapsedSeconds;
    }
    int GetElapsedMS() const
    {
        double dElapsedSeconds = GetElapsedSeconds();
        int nElapsedMilliseconds = static_cast<int>(dElapsedSeconds * 1000.0);
        return nElapsedMilliseconds;
    }

protected:
    APE_TICK_COUNT_TYPE m_Ticks;
};
