#include "All.h"
#include "CharacterHelper.h"

namespace APE
{

str_ansi * CAPECharacterHelper::GetANSIFromUTF8(const str_utf8 * pUTF8)
{
    str_utfn * pUTFN = GetUTFNFromUTF8(pUTF8);
    str_ansi * pANSI = GetANSIFromUTFN(pUTFN);
    delete [] pUTFN;
    return pANSI;
}

str_ansi * CAPECharacterHelper::GetANSIFromUTFN(const str_utfn * pUTFN)
{
    const int nCharacters = pUTFN ? static_cast<int>(wcslen(pUTFN)) : 0;
    #ifdef _WIN32
        const int nANSICharacters = (2 * nCharacters);
        str_ansi * pANSI = new str_ansi [static_cast<size_t>(nANSICharacters + 1)];
        const size_t nBufferBytes = (sizeof(pANSI[0]) * static_cast<size_t>(nCharacters + 1));
        memset(pANSI, 0, nBufferBytes);
        if (pUTFN)
            WideCharToMultiByte(CP_ACP, 0, pUTFN, -1, pANSI, nANSICharacters, APE_NULL, APE_NULL);
    #else
        str_utf8 * pANSI = new str_utf8 [nCharacters + 1];
        for (int z = 0; z < nCharacters; z++)
            pANSI[z] = (pUTFN[z] >= 256) ? '?' : (str_utf8)pUTFN[z];
        pANSI[nCharacters] = 0;
    #endif

    return reinterpret_cast<str_ansi *>(pANSI);
}

str_utfn * CAPECharacterHelper::GetUTFNFromANSI(const str_ansi * pANSI)
{
    const int nCharacters = pANSI ? static_cast<int>(strlen(pANSI)) : 0;
    str_utfn * pUTFN = new str_utfn [static_cast<size_t>(nCharacters + 1)];

    #ifdef _WIN32
        const size_t nBufferBytes = (sizeof(pUTFN[0]) * static_cast<size_t>(nCharacters + 1));
        memset(pUTFN, 0, nBufferBytes);
        if (pANSI)
            MultiByteToWideChar(CP_ACP, 0, pANSI, -1, pUTFN, nCharacters);
    #else
        for (int z = 0; z < nCharacters; z++)
            pUTFN[z] = (str_utfn) ((str_utf8) pANSI[z]);
        pUTFN[nCharacters] = 0;
    #endif

    return pUTFN;
}

str_utfn * CAPECharacterHelper::GetUTFNFromUTF8(const str_utf8 * pUTF8)
{
    // get the length
    int nLength = static_cast<int>(strlen(reinterpret_cast<const char *>(pUTF8))); // calculate the length of the UTF-8 string
    int nCharacters = 0; int nIndex = 0;
    while (pUTF8[nIndex] != 0)
    {
        // get UTF-8 characters in this character
        if ((pUTF8[nIndex] & 0x80) == 0)
            nIndex += 1; // the NULL at the end of the string will hit this
        else if ((pUTF8[nIndex] & 0xF0) == 0xF0)
            nIndex += 4;
        else if ((pUTF8[nIndex] & 0xE0) == 0xE0)
            nIndex += 3;
        else
            nIndex += 2;

        // check against the string length (we should stop at the NULL before hitting this, but this is done as a safety test since there could be a character that says it's four long but there's really only three bytes left)
        if (nIndex > nLength)
            break;

        // this is one character
        nCharacters += 1;
    }

    // make a UTF-N string
    str_utfn * pUTFN = new str_utfn [static_cast<size_t>(nCharacters) + 1];
    str_utfn * pOutput = pUTFN;
    nIndex = 0;
    for (int nCharacter = 0; nCharacter < nCharacters; nCharacter++)
    {
        int64 nCode = 0;
        if ((pUTF8[nIndex] & 0x80) == 0)
        {
            nCode = static_cast<int64>(pUTF8[nIndex]);
            nIndex += 1;
        }
        else if ((pUTF8[nIndex] & 0xF0) == 0xF0)
        {
            // four byte sequences only make sense for UTF-32 but there's no harm in having code here
            nCode = ((static_cast<int64>(pUTF8[nIndex]) & 0x07) << 18) | ((static_cast<int64>(pUTF8[nIndex + 1]) & 0x3F) << 12) | ((static_cast<int64>(pUTF8[nIndex + 2]) & 0x3F) << 6) | (static_cast<int64>(pUTF8[nIndex + 3]) & 0x3F);
            nIndex += 4;
        }
        else if ((pUTF8[nIndex] & 0xE0) == 0xE0)
        {
            nCode = ((static_cast<int64>(pUTF8[nIndex]) & 0x1F) << 12) | ((static_cast<int64>(pUTF8[nIndex + 1]) & 0x3F) << 6) | (static_cast<int64>(pUTF8[nIndex + 2]) & 0x3F);
            nIndex += 3;
        }
        else
        {
            nCode = ((static_cast<int64>(pUTF8[nIndex]) & 0x3F) << 6) | (static_cast<int64>(pUTF8[nIndex + 1]) & 0x3F);
            nIndex += 2;
        }

        // output the UTFN character from the decoded code
        *pOutput++ = GetUTFNCharacter(nCode);
    }
    *pOutput++ = 0; // NULL terminate

    return pUTFN;
}

str_utf8 * CAPECharacterHelper::GetUTF8FromANSI(const str_ansi * pANSI)
{
    str_utfn * pUTFN = GetUTFNFromANSI(pANSI);
    str_utf8 * pUTF8 = GetUTF8FromUTFN(pUTFN);
    delete [] pUTFN;
    return pUTF8;
}

str_utf8 * CAPECharacterHelper::GetUTF8FromUTFN(const str_utfn * pUTFN)
{
    // we support up to UTF-32 even though Windows is UTF-16

    // get the size(s)
    const int nCharacters = static_cast<int>(wcslen(pUTFN));
    int nUTF8Bytes = 0;
    for (int z = 0; z < nCharacters; z++)
    {
        int64 nCharacter = static_cast<int64>(pUTFN[z]);
        if (nCharacter < 0x0080)
            nUTF8Bytes += 1;
        else if (nCharacter < 0x0800)
            nUTF8Bytes += 2;
        else if (nCharacter < 0x10000)
            nUTF8Bytes += 3;
        else
            nUTF8Bytes += 4;
    }

    // allocate a UTF-8 string
    str_utf8 * pUTF8 = new str_utf8 [static_cast<size_t>(nUTF8Bytes) + 1];

    // create the UTF-8 string
    str_utf8 * pOutput = pUTF8;
    for (int z = 0; z < nCharacters; z++)
    {
        int64 nCharacter = static_cast<int64>(pUTFN[z]);
        if (nCharacter < 0x0080)
        {
            *pOutput++ = static_cast<str_utf8>(nCharacter);
        }
        else if (nCharacter < 0x0800)
        {
            *pOutput++ = static_cast<str_utf8>(0xC0 | (nCharacter >> 6));
            *pOutput++ = static_cast<str_utf8>(0x80 | (nCharacter & 0x3F));
        }
        else if (nCharacter < 0x10000)
        {
            *pOutput++ = static_cast<str_utf8>(0xE0 | (nCharacter >> 12));
            *pOutput++ = static_cast<str_utf8>(0x80 | ((nCharacter >> 6) & 0x3F));
            *pOutput++ = static_cast<str_utf8>(0x80 | (nCharacter & 0x3F));
        }
        else
        {
            *pOutput++ = static_cast<str_utf8>(0xF0 | (nCharacter >> 16));
            *pOutput++ = static_cast<str_utf8>(0x80 | ((nCharacter >> 12) & 0x3F));
            *pOutput++ = static_cast<str_utf8>(0x80 | ((nCharacter >> 6) & 0x3F));
            *pOutput++ = static_cast<str_utf8>(0x80 | (nCharacter & 0x3F));
        }
    }
    *pOutput++ = 0;

    // return the UTF-8 string
    return pUTF8;
}

str_utfn CAPECharacterHelper::GetUTFNCharacter(const int64 nCode)
{
    str_utfn cUTFN = static_cast<str_utfn>(nCode);
    if (static_cast<int64>(cUTFN) != nCode)
    {
        // output a broken string since we can't represent the character code with str_utfn
        // this happens on overflow if nCode is too big to be represented by the str_utfn
        cUTFN = '?';
    }
    return cUTFN;
}

}
