#pragma once

/**************************************************************************************************
Windows version
**************************************************************************************************/
#ifdef PLATFORM_WINDOWS_XP
    #undef WINVER
    #undef _WIN32_WINNT

    #define WINVER             0x0501
    #define _WIN32_WINNT       0x0501
#else
    #if !defined(WINVER) && !defined(_WIN32_WINNT)
        #define WINVER         0x0600
        #define _WIN32_WINNT   0x0600
    #elif !defined(WINVER)
        #define WINVER         _WIN32_WINNT
    #elif !defined(_WIN32_WINNT)
        #define _WIN32_WINNT   WINVER
    #endif
#endif

/**************************************************************************************************
Unicode
**************************************************************************************************/
#ifndef UNICODE
    #define UNICODE
#endif
#ifndef _UNICODE
    #define _UNICODE
#endif

/**************************************************************************************************
Visual Studio defines
**************************************************************************************************/
#define _AFX_NO_MFC_CONTROLS_IN_DIALOGS

/**************************************************************************************************
Windows SDK bug fix
NTDDI_WIN10_GE is referenced in shellapi.h but undefined
**************************************************************************************************/
#ifndef NTDDI_WIN10_GE
    #define NTDDI_WIN10_GE 0x0A000010 // Matches the NTDDI_WIN11_GE value
#endif
