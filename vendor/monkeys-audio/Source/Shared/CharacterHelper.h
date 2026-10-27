#pragma once

namespace APE
{

/**************************************************************************************************
Character set conversion helpers
**************************************************************************************************/
class CAPECharacterHelper
{
public:
    static str_ansi * GetANSIFromUTF8(const str_utf8 * pUTF8);
    static str_ansi * GetANSIFromUTFN(const str_utfn * pUTFN);
    static str_utfn * GetUTFNFromANSI(const str_ansi * pANSI);
    static str_utfn * GetUTFNFromUTF8(const str_utf8 * pUTF8);
    static str_utf8 * GetUTF8FromANSI(const str_ansi * pANSI);
    static str_utf8 * GetUTF8FromUTFN(const str_utfn * pUTFN);
    static str_utfn GetUTFNCharacter(const int64 nCode);
};

}
