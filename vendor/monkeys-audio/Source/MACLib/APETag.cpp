#include "All.h"
#include "APETag.h"
#include "CharacterHelper.h"
#include "IAPEIO.h"
#include "GlobalFunctions.h"
#include "MACLib.h"

namespace APE
{

/**************************************************************************************************
CAPETagField
**************************************************************************************************/
CAPETagField::CAPETagField(const str_utfn * pFieldName, const void * pFieldValue, int nFieldBytes, int nFlags)
{
    // field name
    size_t nFieldNameLength = wcslen(pFieldName);
    m_spFieldNameUTFN.AllocateArray(static_cast<int64>(nFieldNameLength) + 1);
    memcpy(m_spFieldNameUTFN, pFieldName, (nFieldNameLength + 1) * sizeof(m_spFieldNameUTFN[0]));

    // data (we'll always allocate two extra bytes and memset to 0 so we're safely NULL terminated)
    m_nFieldValueBytes = APE_MAX(nFieldBytes, 0);
    m_spFieldValue.AllocateArray(static_cast<int64>(m_nFieldValueBytes) + 2, true);
    if (m_nFieldValueBytes > 0)
        memcpy(m_spFieldValue, pFieldValue, static_cast<size_t>(m_nFieldValueBytes));

    // flags
    m_nFieldFlags = nFlags;
}

CAPETagField::~CAPETagField()
{
    m_spFieldNameUTFN.Delete();
    m_spFieldValue.Delete();
}

int CAPETagField::GetFieldSize() const
{
    CSmartPtr<char> spFieldNameANSI(CAPECharacterHelper::GetANSIFromUTFN(m_spFieldNameUTFN), true);
    return (static_cast<int>(strlen(spFieldNameANSI) + 1)) + m_nFieldValueBytes + 4 + 4;
}

const str_utfn * CAPETagField::GetFieldName() const
{
    return m_spFieldNameUTFN;
}

const char * CAPETagField::GetFieldValue()
{
    return m_spFieldValue;
}

int CAPETagField::GetFieldValueSize() const
{
    return m_nFieldValueBytes;
}

int CAPETagField::GetFieldFlags() const
{
    return m_nFieldFlags;
}

void CAPETagField::Save32(char * pBuffer, int nValue)
{
    pBuffer[0] = static_cast<char>(nValue);
    pBuffer[1] = static_cast<char>(nValue >> 8);
    pBuffer[2] = static_cast<char>(nValue >> 16);
    pBuffer[3] = static_cast<char>(nValue >> 24);
}

bool CAPETagField::GetIsReadOnly() const
{
    return (m_nFieldFlags & TAG_FIELD_FLAG_READ_ONLY) ? true : false;
}

bool CAPETagField::GetIsUTF8Text() const
{
    return ((m_nFieldFlags & TAG_FIELD_FLAG_DATA_TYPE_MASK) == TAG_FIELD_FLAG_DATA_TYPE_TEXT_UTF8) ? true : false;
}

int CAPETagField::SaveField(char * pBuffer, int nBytes)
{
    Save32(pBuffer, m_nFieldValueBytes);
    pBuffer += 4;
    Save32(pBuffer, m_nFieldFlags);
    pBuffer += 4;
    nBytes -= 8;

    CSmartPtr<char> spFieldNameANSI(static_cast<char *>(CAPECharacterHelper::GetANSIFromUTFN(m_spFieldNameUTFN)), true);
    strcpy_s(pBuffer, static_cast<size_t>(nBytes), spFieldNameANSI);
    pBuffer += strlen(spFieldNameANSI) + 1;
    nBytes -= static_cast<int>(strlen(spFieldNameANSI)) + 1;

    memcpy(pBuffer, m_spFieldValue, static_cast<size_t>(APE_MIN(m_nFieldValueBytes, nBytes)));

    return GetFieldSize();
}

/**************************************************************************************************
CAPETag
**************************************************************************************************/
const str_utfn * CAPETag::s_aryID3GenreNames[CAPETag::s_nID3GenreCount] =
{
    L"Blues", L"Classic Rock", L"Country", L"Dance", L"Disco", L"Funk", L"Grunge", L"Hip-Hop",
    L"Jazz", L"Metal", L"New Age", L"Oldies", L"Other", L"Pop", L"R&B", L"Rap", L"Reggae", L"Rock", L"Techno",
    L"Industrial", L"Alternative", L"Ska", L"Death Metal", L"Pranks", L"Soundtrack", L"Euro-Techno", L"Ambient",
    L"Trip-Hop", L"Vocal", L"Jazz+Funk", L"Fusion", L"Trance", L"Classical", L"Instrumental", L"Acid", L"House", L"Game",
    L"Sound Clip", L"Gospel", L"Noise", L"AlternRock", L"Bass", L"Soul", L"Punk", L"Space", L"Meditative", L"Instrumental Pop",
    L"Instrumental Rock", L"Ethnic", L"Gothic", L"Darkwave", L"Techno-Industrial", L"Electronic", L"Pop-Folk", L"Eurodance",
    L"Dream", L"Southern Rock", L"Comedy", L"Cult", L"Gangsta", L"Top 40", L"Christian Rap", L"Pop/Funk", L"Jungle",
    L"Native American", L"Cabaret", L"New Wave", L"Psychedelic", L"Rave", L"Showtunes", L"Trailer", L"Lo-Fi", L"Tribal",
    L"Acid Punk", L"Acid Jazz", L"Polka", L"Retro", L"Musical", L"Rock & Roll", L"Hard Rock", L"Folk", L"Folk-Rock", L"National Folk",
    L"Swing", L"Fast Fusion", L"Bebop", L"Latin", L"Revival", L"Celtic", L"Bluegrass", L"Avantgarde", L"Gothic Rock", L"Progressive Rock",
    L"Psychedelic Rock", L"Symphonic Rock", L"Slow Rock", L"Big Band", L"Chorus", L"Easy Listening", L"Acoustic", L"Humour",
    L"Speech", L"Chanson", L"Opera", L"Chamber Music", L"Sonata", L"Symphony", L"Booty Bass", L"Primus", L"Porn Groove",
    L"Satire", L"Slow Jam", L"Club", L"Tango", L"Samba", L"Folklore", L"Ballad", L"Power Ballad", L"Rhythmic Soul", L"Freestyle",
    L"Duet", L"Punk Rock", L"Drum Solo", L"Acapella", L"Euro-House", L"Dance Hall", L"Goa", L"Drum & Bass", L"Club House", L"Hardcore",
    L"Terror", L"Indie", L"BritPop", L"Black Punk", L"Polsk Punk", L"Beat", L"Christian Gangsta", L"Heavy Metal", L"Black Metal",
    L"Crossover", L"Contemporary C", L"Christian Rock", L"Merengue", L"Salsa", L"Thrash Metal", L"Anime", L"JPop", L"SynthPop"
};

CAPETag::CAPETag(const str_utfn * pFilename, bool bAnalyze)
{
    m_spIO.Assign(CreateIAPEIO());
    m_spIO->Open(pFilename);

    m_aryFields = APE_NULL;
    m_nTagBytes = 0;
    m_nAPETagVersion = -1;
    m_nFields = 0;
    m_nAllocatedFields = 0;
    m_bAnalyzed = false;
    m_bHasAPETag = false;
    m_bHasID3Tag = false;
    m_bIgnoreReadOnly = false;
    m_bCheckForID3v1 = true;

    if (bAnalyze)
        Analyze();
}

CAPETag::CAPETag(IAPEIO * pIO, bool bAnalyze, bool bCheckForID3v1)
{
    m_spIO.Assign(pIO, false, false); // we don't own the IO source
    m_bAnalyzed = false;
    m_nFields = 0;
    m_nAllocatedFields = 0;
    m_aryFields = APE_NULL;
    m_nTagBytes = 0;
    m_bIgnoreReadOnly = false;
    m_bHasAPETag = false;
    m_bHasID3Tag = false;
    m_nAPETagVersion = -1;
    m_bCheckForID3v1 = bCheckForID3v1;

    if (bAnalyze)
    {
        Analyze();
    }
}

CAPETag::~CAPETag()
{
    CAPETag::ClearFields(); // call CAPETag because calling the interface function is gone
    APE_SAFE_ARRAY_DELETE(m_aryFields)
}

bool CAPETag::GetAnalyzed()
{
    return m_bAnalyzed;
}

int CAPETag::GetTagBytes()
{
    if (!m_bAnalyzed) { Analyze(); }

    return m_nTagBytes;
}

IAPETagField * CAPETag::GetTagField(int nIndex)
{
    if (!m_bAnalyzed) { Analyze(); }

    if ((nIndex >= 0) && (nIndex < m_nFields))
    {
        return m_aryFields[nIndex];
    }

    return APE_NULL;
}

int CAPETag::Save(bool bUseOldID3)
{
    if (Remove(false) != APE_ERROR_SUCCESS)
        return APE_ERROR_UNDEFINED;

    if (m_nFields == 0) { return APE_ERROR_SUCCESS; }

    int nResult = APE_ERROR_UNDEFINED;

    if (bUseOldID3 == false)
    {
        int z = 0;

        // calculate the size of the whole tag
        int nFieldBytes = 0;
        for (z = 0; z < m_nFields; z++)
            nFieldBytes += m_aryFields[z]->GetFieldSize();

        // sort the fields
        SortFields();

        // build the footer
        APE_TAG_FOOTER APETagFooter(m_nFields, nFieldBytes);

        // make a buffer for the tag
        const int nTotalTagBytes = APETagFooter.GetTotalTagBytes();
        CSmartPtr<char> spRawTag(new char [static_cast<size_t>(nTotalTagBytes)], true);

        // save the fields
        int nLocation = 0;
        for (z = 0; z < m_nFields; z++)
            nLocation += m_aryFields[z]->SaveField(&spRawTag[nLocation], nTotalTagBytes - nLocation);

        // add the footer to the buffer
        memcpy(&spRawTag[nLocation], &APETagFooter, APE_TAG_FOOTER_BYTES);
        //nLocation += APE_TAG_FOOTER_BYTES; // we grow by this many, but nothing ever uses nLocation again

        // dump the tag to the I/O source
        nResult = WriteBufferToEndOfIO(spRawTag, nTotalTagBytes);
    }
    else if (bUseOldID3 && (sizeof(ID3_TAG) == ID3_TAG_BYTES))
    {
        // build the ID3 tag
        ID3_TAG ID3Tag;
        nResult = CreateID3Tag(&ID3Tag);
        if (nResult == APE_ERROR_SUCCESS)
            nResult = WriteBufferToEndOfIO(&ID3Tag, ID3_TAG_BYTES);
    }

    return nResult;
}

int CAPETag::WriteBufferToEndOfIO(void * pBuffer, int nBytes)
{
    const int64 nOriginalPosition = m_spIO->GetPosition();

    m_spIO->Seek(0, SeekFileEnd);

    const int nResult = m_spIO->Write(pBuffer, nBytes);

    m_spIO->Seek(nOriginalPosition, SeekFileBegin);

    return nResult;
}

int CAPETag::Analyze()
{
    // clean-up
    ID3_TAG ID3Tag; APE_CLEAR(ID3Tag);
    ClearFields();
    m_nTagBytes = 0;

    m_bAnalyzed = true;

    // store the original location
    const int64 nOriginalPosition = m_spIO->GetPosition();

    // remove tag markers
    m_bHasID3Tag = false;
    m_bHasAPETag = false;
    m_nAPETagVersion = -1;

    // check for an ID3v1 tag
    if (m_bCheckForID3v1 && (sizeof(ID3Tag) == ID3_TAG_BYTES) && (m_spIO->GetSize() > ID3_TAG_BYTES))
    {
        if (m_spIO->Seek(-ID3_TAG_BYTES, SeekFileEnd) == APE_ERROR_SUCCESS)
        {
            int64 nBytesRead = 0;
            const int nReadRetVal = m_spIO->Read(&ID3Tag, ID3_TAG_BYTES, &nBytesRead);
            if ((nBytesRead == ID3_TAG_BYTES) && (nReadRetVal == 0))
            {
                if (ID3Tag.Header[0] == 'T' && ID3Tag.Header[1] == 'A' && ID3Tag.Header[2] == 'G')
                {
                    m_bHasID3Tag = true;
                    m_nTagBytes += ID3_TAG_BYTES;
                }
            }
        }
    }

    // set the fields
    if (m_bHasID3Tag)
    {
        SetFieldID3String(APE_TAG_FIELD_ARTIST, ID3Tag.Artist, 30);
        SetFieldID3String(APE_TAG_FIELD_ALBUM, ID3Tag.Album, 30);
        SetFieldID3String(APE_TAG_FIELD_TITLE, ID3Tag.Title, 30);
        SetFieldID3String(APE_TAG_FIELD_COMMENT, ID3Tag.Comment, 28);
        SetFieldID3String(APE_TAG_FIELD_YEAR, ID3Tag.Year, 4);

        str_ansi cTrack[16]; APE_CLEAR(cTrack);
        snprintf(cTrack, 16, "%d", ID3Tag.Track);
        SetFieldString(APE_TAG_FIELD_TRACK, cTrack, false);

        if ((ID3Tag.Genre == CAPETag::s_nID3GenreUndefined) || (ID3Tag.Genre >= CAPETag::s_nID3GenreCount))
            SetFieldString(APE_TAG_FIELD_GENRE, APE_TAG_GENRE_UNDEFINED);
        else
            SetFieldString(APE_TAG_FIELD_GENRE, CAPETag::s_aryID3GenreNames[ID3Tag.Genre]);
    }

    // try loading the APE tag
    // we used to not load if we found an ID3 tag, but somebody sent me a file with both an ID3 tag and APE tag, so we'll try to parse that going forward
    {
        APE_TAG_FOOTER APETagFooter;
        int nTagBytes = static_cast<int>(APE_TAG_FOOTER_BYTES + (m_bHasID3Tag ? ID3_TAG_BYTES : 0));
        if (m_spIO->Seek(-nTagBytes, SeekFileEnd) == APE_ERROR_SUCCESS)
        {
            int64 nBytesRead = 0;
            APETagFooter.Empty();
            int nReadRetVal = m_spIO->Read(&APETagFooter, APE_TAG_FOOTER_BYTES, &nBytesRead);
            if ((nBytesRead == APE_TAG_FOOTER_BYTES) && (nReadRetVal == 0))
            {
                if (APETagFooter.GetIsValid(false))
                {
                    m_bHasAPETag = true;
                    m_nAPETagVersion = APETagFooter.GetVersion();

                    const int nRawFieldBytes = APETagFooter.GetFieldBytes();
                    m_nTagBytes += APETagFooter.GetTotalTagBytes();

                    CSmartPtr<char> spRawTag(new char [static_cast<size_t>(nRawFieldBytes)], true);
                    if (m_spIO->Seek(static_cast<int64>(-(APETagFooter.GetTotalTagBytes() - APETagFooter.GetFieldsOffset() + (m_bHasID3Tag ? ID3_TAG_BYTES : 0))), SeekFileEnd) == APE_ERROR_SUCCESS)
                    {
                        nReadRetVal = m_spIO->Read(spRawTag.GetPtr(), nRawFieldBytes, &nBytesRead);

                        if ((nReadRetVal == 0) && (nRawFieldBytes == static_cast<int>(nBytesRead)))
                        {
                            // parse out the raw fields
                            int nLocation = 0;
                            for (int z = 0; z < APETagFooter.GetNumberFields(); z++)
                            {
                                const int nMaximumFieldBytes = nRawFieldBytes - nLocation;

                                int nBytes = 0;
                                if (LoadField(&spRawTag[nLocation], nMaximumFieldBytes, &nBytes) != APE_ERROR_SUCCESS)
                                {
                                    // if LoadField(...) fails, it means that the tag is corrupt (accidentally or intentionally)
                                    // we'll just bail out -- leaving the fields we've already set
                                    break;
                                }
                                nLocation += nBytes;
                            }
                        }
                    }
                }
            }
        }
    }

    // restore the file pointer
    m_spIO->Seek(nOriginalPosition, SeekFileBegin);

    return APE_ERROR_SUCCESS;
}

int CAPETag::ClearFields()
{
    for (int z = 0; z < m_nFields; z++)
    {
        APE_SAFE_DELETE(m_aryFields[z])
    }

    m_nFields = 0;

    return APE_ERROR_SUCCESS;
}

int CAPETag::GetTagFieldIndex(const str_utfn * pFieldName)
{
    if (!m_bAnalyzed) { Analyze(); }
    if (pFieldName != APE_NULL)
    {
        for (int z = 0; z < m_nFields; z++)
        {
            if (StringIsEqual(m_aryFields[z]->GetFieldName(), pFieldName, false))
                return z;
        }
    }
    return -1;
}

IAPETagField * CAPETag::GetTagField(const str_utfn * pFieldName)
{
    int nIndex = GetTagFieldIndex(pFieldName);
    return (nIndex != -1) ? m_aryFields[nIndex] : APE_NULL;
}

int CAPETag::GetFieldString(const str_utfn * pFieldName, str_ansi * pBuffer, int * pBufferCharacters, bool bUTF8Encode)
{
    const int nOriginalCharacters = *pBufferCharacters;
    CSmartPtr<str_utfn> spUTFN(new str_utfn[static_cast<size_t>(*pBufferCharacters) + 1], true);
    spUTFN[0] = 0;

    int nResult = GetFieldString(pFieldName, spUTFN, pBufferCharacters);
    if (nResult == APE_ERROR_SUCCESS)
    {
        CSmartPtr<str_ansi> spANSI(bUTF8Encode ? reinterpret_cast<str_ansi *>(CAPECharacterHelper::GetUTF8FromUTFN(spUTFN)) : CAPECharacterHelper::GetANSIFromUTFN(spUTFN), true);
        if (static_cast<int>(strlen(spANSI)) > nOriginalCharacters)
        {
            APE_CLEAR_ARRAY(pBuffer, nOriginalCharacters);
            *pBufferCharacters = 0;
            nResult = APE_ERROR_UNDEFINED;
        }
        else
        {
            strcpy_s(pBuffer, static_cast<size_t>(nOriginalCharacters), spANSI);
            *pBufferCharacters = static_cast<int>(strlen(spANSI));
        }
    }

    spUTFN.Delete();

    return nResult;
}

int CAPETag::GetFieldString(const str_utfn * pFieldName, str_utfn * pBuffer, int * pBufferCharacters, const str_utfn * pListDelimiter)
{
    if (!m_bAnalyzed) { Analyze(); }

    int nResult = APE_ERROR_UNDEFINED;

    if ((pBuffer != APE_NULL) && (*pBufferCharacters > 0) && (pListDelimiter != APE_NULL))
    {
        // empty result
        pBuffer[0] = 0;

        // get field
        IAPETagField * pAPETagField = GetTagField(pFieldName);
        if (pAPETagField == APE_NULL)
        {
            // the field doesn't exist -- return an empty string
            APE_CLEAR_ARRAY(pBuffer, *pBufferCharacters);
            *pBufferCharacters = 0;
        }
        else if (pAPETagField->GetIsUTF8Text() || (m_nAPETagVersion < 2000))
        {
            // find next NULL
            int nListItemStartIndex = 0;
            int nOutputCharacters = 0;
            const int nListDelimiterCharacters = static_cast<int>(wcslen(pListDelimiter));

            // loop each list item
            nResult = APE_ERROR_SUCCESS;
            while (nListItemStartIndex < pAPETagField->GetFieldValueSize())
            {
                // get the value in UTF-N format
                CSmartPtr<str_utfn> spUTFN;
                if (m_nAPETagVersion >= 2000)
                    spUTFN.Assign(CAPECharacterHelper::GetUTFNFromUTF8(reinterpret_cast<const str_utf8 *>(&pAPETagField->GetFieldValue()[nListItemStartIndex])), true);
                else
                    spUTFN.Assign(CAPECharacterHelper::GetUTFNFromANSI(&pAPETagField->GetFieldValue()[nListItemStartIndex]), true);

                // get the number of characters
                const int nCharacters = (static_cast<int>(wcslen(spUTFN)) + 1);

                int nNeededCharacters = nOutputCharacters + nCharacters;
                if (pBuffer[0] != 0)
                    nNeededCharacters += nListDelimiterCharacters;

                if (nNeededCharacters > *pBufferCharacters)
                {
                    // we'll fail here, because it's not clear what would get returned (null termination, size, etc.)
                    // and we really don't want to cause buffer overruns on the client side
                    // we use (nListDelimiterCharacters - 1) since there's already a NULL delimiter in the field
                    *pBufferCharacters = (pAPETagField->GetFieldValueSize() + 1) + ((nListDelimiterCharacters - 1) * 64); // worst-case scenario
                    nResult = APE_ERROR_BAD_PARAMETER;
                    break;
                }
                else
                {
                    // copy list item to output

                    // delimiter
                    if (pBuffer[0] != 0)
                    {
                        wcscat_s(pBuffer, static_cast<size_t>(*pBufferCharacters), pListDelimiter);
                        nOutputCharacters += nListDelimiterCharacters;
                    }

                    // value
                    wcscat_s(pBuffer, static_cast<size_t>(*pBufferCharacters), spUTFN.GetPtr());
                    nOutputCharacters += nCharacters;
                }

                // find the next list item start index
                while (nListItemStartIndex < pAPETagField->GetFieldValueSize())
                {
                    if (pAPETagField->GetFieldValue()[nListItemStartIndex] == 0)
                    {
                        // found another item
                        nListItemStartIndex += 1; // start after the NULL
                        break;
                    }
                    nListItemStartIndex++;
                }
            }

            // output characters
            if (nResult == APE_ERROR_SUCCESS)
                *pBufferCharacters = nOutputCharacters;
        }
        else
        {
            // memset the whole buffer to NULL (so everything left over is NULL terminated)
            APE_CLEAR_ARRAY(pBuffer, *pBufferCharacters);

            // do a binary dump (need to convert from wchar's to bytes)
            int nBufferBytes = (*pBufferCharacters - 1) * static_cast<int>(sizeof(pBuffer[0]));
            nResult = GetFieldBinary(pFieldName, pBuffer, &nBufferBytes);
            *pBufferCharacters = (nBufferBytes / static_cast<int>(sizeof(pBuffer[0]))) + 1;
        }
    }

    return nResult;
}

int CAPETag::GetFieldNumber(const str_utfn * pFieldName, int nNotFoundResult)
{
    int nRetVal = nNotFoundResult;

    char cNumber[64]; APE_CLEAR(cNumber);
    int nBufferCharacters = 63;
    if (GetFieldString(pFieldName, &cNumber[0], &nBufferCharacters) == APE_ERROR_SUCCESS)
    {
        nRetVal = atoi(cNumber);
    }

    return nRetVal;
}

int CAPETag::GetFieldBinary(const str_utfn * pFieldName, void * pBuffer, int * pBufferBytes)
{
    if (!m_bAnalyzed) { Analyze(); }

    int nResult = APE_ERROR_UNDEFINED;

    if (*pBufferBytes > 0)
    {
        IAPETagField * pAPETagField = GetTagField(pFieldName);
        if (pAPETagField == APE_NULL)
        {
            memset(pBuffer, 0, static_cast<size_t>(*pBufferBytes));
            *pBufferBytes = 0;
        }
        else
        {
            if (pAPETagField->GetFieldValueSize() > *pBufferBytes)
            {
                // we'll fail here, because partial data may be worse than no data
                memset(pBuffer, 0, static_cast<size_t>(*pBufferBytes));
                *pBufferBytes = pAPETagField->GetFieldValueSize();
            }
            else
            {
                // memcpy
                *pBufferBytes = pAPETagField->GetFieldValueSize();
                memcpy(pBuffer, pAPETagField->GetFieldValue(), static_cast<size_t>(*pBufferBytes));
                nResult = APE_ERROR_SUCCESS;
            }
        }
    }

    return nResult;
}

int CAPETag::CreateID3Tag(ID3_TAG * pID3Tag)
{
    // error check
    if (pID3Tag == APE_NULL) { return APE_ERROR_UNDEFINED; }
    if (!m_bAnalyzed) { Analyze(); }
    if (m_nFields == 0) { return APE_ERROR_UNDEFINED; }

    // empty
    APE_CLEAR(*pID3Tag);

    // header
    pID3Tag->Header[0] = 'T'; pID3Tag->Header[1] = 'A'; pID3Tag->Header[2] = 'G';

    // standard fields
    GetFieldID3String(APE_TAG_FIELD_ARTIST, pID3Tag->Artist, 30);
    GetFieldID3String(APE_TAG_FIELD_ALBUM, pID3Tag->Album, 30);
    GetFieldID3String(APE_TAG_FIELD_TITLE, pID3Tag->Title, 30);
    GetFieldID3String(APE_TAG_FIELD_COMMENT, pID3Tag->Comment, 29);
    GetFieldID3String(APE_TAG_FIELD_YEAR, pID3Tag->Year, 4);

    // track number
    str_utfn cBuffer[256]; APE_CLEAR(cBuffer); int nBufferCharacters = 255;
    GetFieldString(APE_TAG_FIELD_TRACK, cBuffer, &nBufferCharacters);
    pID3Tag->Track = static_cast<unsigned char>(_wtoi(cBuffer));

    // genre
    cBuffer[0] = 0; nBufferCharacters = 255;
    GetFieldString(APE_TAG_FIELD_GENRE, cBuffer, &nBufferCharacters);

    // convert the genre string to an index
    pID3Tag->Genre = 255;
    int nGenreIndex = 0;
    bool bFound = false;
    while ((nGenreIndex < CAPETag::s_nID3GenreCount) && !bFound)
    {
        if (StringIsEqual(cBuffer, s_aryID3GenreNames[nGenreIndex], false))
        {
            pID3Tag->Genre = static_cast<unsigned char>(nGenreIndex);
            bFound = true;
        }

        nGenreIndex++;
    }

    return APE_ERROR_SUCCESS;
}

bool CAPETag::GetHasID3Tag()
{
    if (!m_bAnalyzed) { Analyze(); }
    return m_bHasID3Tag;
}

bool CAPETag::GetHasAPETag()
{
    if (!m_bAnalyzed) { Analyze(); }
    return m_bHasAPETag;
}

int CAPETag::GetAPETagVersion()
{
    return GetHasAPETag() ? m_nAPETagVersion : -1;
}

bool CAPETag::GetIOMatches(IAPEIO * pIO)
{
    return (m_spIO == pIO);
}

void CAPETag::SetIgnoreReadOnly(bool bIgnoreReadOnly)
{
    m_bIgnoreReadOnly = bIgnoreReadOnly;
}

int CAPETag::OutputTag(str_utfn * pOutput, int nOutputLength)
{
    // empty output
    pOutput[0] = 0;

    // output tag type
    const int nTagSize = 256;
    str_utfn cTag[nTagSize]; APE_CLEAR(cTag);
    wcscpy_s(cTag, nTagSize, L"None");
    bool bKeepAppending = true;
    if (GetHasAPETag())
    {
        swprintf(cTag, nTagSize, L"APE Tag v%.2f", static_cast<double>(GetAPETagVersion()) / static_cast<double>(1000));
        if (GetHasID3Tag())
            SafeStringAppend(cTag, nTagSize, L", ID3v1.1", bKeepAppending);
    }
    else if (GetHasID3Tag())
    {
        wcscpy_s(cTag, nTagSize, L"ID3v1.1");
    }

    const int nLineSize = 4096;
    str_utfn cLine[nLineSize]; APE_CLEAR(cLine);
    swprintf(cLine, nLineSize, L"Tag: %s (%d bytes)", cTag, GetTagBytes());

    SafeStringAppend(pOutput, static_cast<size_t>(nOutputLength), cLine, bKeepAppending);
    SafeStringAppend(pOutput, static_cast<size_t>(nOutputLength), L"\r\n", bKeepAppending);

    // output tag fields
    int nTagIndex = 0; IAPETagField * pTagField = APE_NULL;
    while ((pTagField = GetTagField(nTagIndex++)) != APE_NULL)
    {
        if (pTagField->GetFieldFlags() & TAG_FIELD_FLAG_DATA_TYPE_BINARY)
        {
            swprintf(cLine, nLineSize, L"    %s: binary value (%d bytes)", pTagField->GetFieldName(), pTagField->GetFieldValueSize());

            SafeStringAppend(pOutput, static_cast<size_t>(nOutputLength), cLine, bKeepAppending);
            SafeStringAppend(pOutput, static_cast<size_t>(nOutputLength), L"\r\n", bKeepAppending);
        }
        else
        {
            const int nMaximumSize = 1024;
            str_utfn cValue[nMaximumSize];
            APE_CLEAR(cValue);
            int nValueBytes = nMaximumSize - 1;
            GetFieldString(pTagField->GetFieldName(), &cValue[0], &nValueBytes);

            if (nValueBytes >= nMaximumSize)
                swprintf(cValue, 1024, L"<too large to display> (%d bytes)", nValueBytes);

            swprintf(cLine, nLineSize, L"    %s: %s",
                pTagField->GetFieldName(),
                cValue);
            SafeStringAppend(pOutput, static_cast<size_t>(nOutputLength), cLine, bKeepAppending);
            SafeStringAppend(pOutput, static_cast<size_t>(nOutputLength), L"\r\n", bKeepAppending);
        }
    }

    return APE_ERROR_SUCCESS;
}

static inline int Load32(const void * a)
{
    return
        (static_cast<int>((static_cast<const unsigned char *>(a))[0]) << 0) |
        (static_cast<int>((static_cast<const unsigned char *>(a))[1]) << 8) |
        (static_cast<int>((static_cast<const unsigned char *>(a))[2]) << 16) |
        (static_cast<int>((static_cast<const unsigned char *>(a))[3]) << 24);
}

int CAPETag::LoadField(const char * pBuffer, int nMaximumBytes, int * pBytes)
{
    // set bytes to 0
    if (pBytes) *pBytes = 0;

    // size and flags
    if (nMaximumBytes < 8)
        return APE_ERROR_UNDEFINED;
    int nLocation = 0;
    const int nFieldValueSize = Load32(&pBuffer[nLocation]);
    if (nFieldValueSize < 1 || nFieldValueSize > (nMaximumBytes - 8))
        return APE_ERROR_UNDEFINED;
    nLocation += 4;
    const int nFieldFlags = Load32(&pBuffer[nLocation]);
    nLocation += 4;

    // safety check (so we can't get buffer overflow attacked)
    bool bSafe = false;
    const int nMaximumRead = nMaximumBytes - 8 - nFieldValueSize;
    if (nMaximumRead > 0)
    {
        for (int z = 0; z < nMaximumRead; z++)
        {
            const int nCharacter = static_cast<int>(static_cast<unsigned char>(pBuffer[nLocation + z])); // treat the buffer as 0-255 instead of of possibly negative
            if (nCharacter == 0)
            {
                bSafe = true;
                break;
            }
            if ((nCharacter < 0x20) || (nCharacter > 0x7E))
                break;
        }
    }
    if (!bSafe)
        return APE_ERROR_UNDEFINED;

    // name
    const int nNameCharacters = static_cast<int>(strlen(&pBuffer[nLocation]));
    CSmartPtr<str_utf8> spNameUTF8(new str_utf8 [static_cast<size_t>(nNameCharacters) + 1], true);
    memcpy(spNameUTF8, &pBuffer[nLocation], (static_cast<size_t>(nNameCharacters) + 1) * sizeof(spNameUTF8[0]));
    nLocation += nNameCharacters + 1;
    CSmartPtr<str_utfn> spNameUTFN(CAPECharacterHelper::GetUTFNFromUTF8(spNameUTF8.GetPtr()), true);

    // value
    CSmartPtr<char> spFieldBuffer(new char [static_cast<size_t>(nFieldValueSize)], true);
    memcpy(spFieldBuffer, &pBuffer[nLocation], static_cast<size_t>(nFieldValueSize));
    nLocation += nFieldValueSize;

    // update the bytes
    if (pBytes) *pBytes = nLocation;

    // set
    return SetFieldBinary(spNameUTFN.GetPtr(), spFieldBuffer, nFieldValueSize, nFieldFlags);
}

int CAPETag::SetFieldString(const str_utfn * pFieldName, const str_utfn * pFieldValue, const str_utfn * pListDelimiter)
{
    // remove if empty
    if ((pFieldValue == APE_NULL) || (wcslen(pFieldValue) <= 0))
        return RemoveField(pFieldName);

    // UTF-8 encode the value and call the UTF-8 SetField(...)
    CSmartPtr<str_utf8> spFieldValueUTF8(CAPECharacterHelper::GetUTF8FromUTFN(reinterpret_cast<const str_utfn *>(pFieldValue)), true);
    return SetFieldString(pFieldName, reinterpret_cast<const char *>(spFieldValueUTF8.GetPtr()), true, pListDelimiter);
}

int CAPETag::SetFieldString(const str_utfn * pFieldName, const char * pFieldValue, bool bAlreadyUTF8Encoded, const str_utfn * pListDelimiter)
{
    // remove if empty
    if ((pFieldValue == APE_NULL) || (strlen(pFieldValue) <= 0))
        return RemoveField(pFieldName);

    if (pListDelimiter != APE_NULL)
    {
        // convert from a caller-specified delimiter to NULL delimiting for use in the tag

        // build UTF-8 string
        CSmartPtr<char> spValueUTF8;
        if (bAlreadyUTF8Encoded)
        {
            const intn nCharacters = static_cast<intn>(strlen(pFieldValue)) + 1;
            spValueUTF8.AllocateArray(nCharacters);
            strcpy_s(spValueUTF8, static_cast<size_t>(nCharacters), pFieldValue);
        }
        else
        {
            spValueUTF8.Assign(reinterpret_cast<char *>(CAPECharacterHelper::GetUTF8FromANSI(pFieldValue)), true);
        }

        // get length
        int nValueBytes = static_cast<int>(strlen(static_cast<const char *>(spValueUTF8)));

        // convert from semi-colon delimited to NULL delimited for list fields
        for (int nCharacter = nValueBytes - 1; nCharacter >= 0; nCharacter--)
        {
            if (spValueUTF8[nCharacter] == ';')
            {
                // remove space following delimiter (so we change "a; b; c" to "a;b;c")
                if (spValueUTF8[nCharacter + 1] == ' ')
                {
                    memmove(&spValueUTF8[nCharacter], &spValueUTF8[static_cast<size_t>(nCharacter) + 1], static_cast<size_t>(nValueBytes) - static_cast<size_t>(nCharacter));
                    nValueBytes -= 1;
                }

                // convert from semi-colon to NULL
                spValueUTF8[nCharacter] = 0;
            }
        }

        return SetFieldBinary(pFieldName, spValueUTF8.GetPtr(), nValueBytes, TAG_FIELD_FLAG_DATA_TYPE_TEXT_UTF8);
    }
    else
    {
        // get the length and call the binary SetField(...)
        if (!bAlreadyUTF8Encoded)
        {
            CSmartPtr<char> spUTF8(reinterpret_cast<char *>(CAPECharacterHelper::GetUTF8FromANSI(pFieldValue)), true);
            const intn nFieldBytes = static_cast<intn>(strlen(spUTF8.GetPtr()));
            return SetFieldBinary(pFieldName, spUTF8.GetPtr(), nFieldBytes, TAG_FIELD_FLAG_DATA_TYPE_TEXT_UTF8);
        }
        else
        {
            const intn nFieldBytes = static_cast<intn>(strlen(pFieldValue));
            return SetFieldBinary(pFieldName, pFieldValue, nFieldBytes, TAG_FIELD_FLAG_DATA_TYPE_TEXT_UTF8);
        }
    }
}

int CAPETag::SetFieldBinary(const str_utfn * pFieldName, const void * pFieldValue, intn nFieldBytes, int nFieldFlags)
{
    if (!m_bAnalyzed) { Analyze(); }
    if (pFieldName == APE_NULL) return APE_ERROR_UNDEFINED;
    if (m_nFields >= m_nAllocatedFields)
    {
        const int nOriginalAllocatedFields = m_nAllocatedFields;
        m_nAllocatedFields *= 2;
        m_nAllocatedFields = APE_MAX(m_nAllocatedFields, 256);
        CAPETagField ** paryFields = new CAPETagField * [static_cast<size_t>(m_nAllocatedFields)];
        if (nOriginalAllocatedFields > 0)
            memcpy(static_cast<void *>(paryFields), static_cast<const void *>(&m_aryFields[0]), sizeof(paryFields[0]) * static_cast<size_t>(nOriginalAllocatedFields));
        APE_SAFE_ARRAY_DELETE(m_aryFields)
        m_aryFields = paryFields;
    }

    // check to see if we're trying to remove the field (by setting it to NULL or an empty string)
    const bool bRemoving = (pFieldValue == APE_NULL) || (nFieldBytes <= 0);

    // get the index
    int nFieldIndex = GetTagFieldIndex(pFieldName);
    if (nFieldIndex != -1)
    {
        // existing field

        // fail if we're read-only (and not ignoring the read-only flag)
        if (!m_bIgnoreReadOnly && (m_aryFields[nFieldIndex]->GetIsReadOnly()))
            return APE_ERROR_UNDEFINED;

        // erase the existing field
        APE_SAFE_DELETE(m_aryFields[nFieldIndex])

        if (bRemoving)
        {
            return RemoveField(nFieldIndex);
        }
    }
    else
    {
        if (bRemoving)
            return APE_ERROR_SUCCESS;

        nFieldIndex = m_nFields;
        m_nFields++;
    }

    // create the field and add it to the field array
    m_aryFields[nFieldIndex] = new CAPETagField(pFieldName, pFieldValue, static_cast<int>(nFieldBytes), nFieldFlags);

    return APE_ERROR_SUCCESS;
}

int CAPETag::RemoveField(int nIndex)
{
    if ((nIndex >= 0) && (nIndex < m_nFields))
    {
        if (m_aryFields[nIndex] != APE_NULL)
        {
            delete m_aryFields[nIndex];
            m_aryFields[nIndex] = APE_NULL;
        }
        
        memmove(static_cast<void *>(&m_aryFields[nIndex]), static_cast<void *>(&m_aryFields[static_cast<size_t>(nIndex) + 1]), (static_cast<size_t>(m_nAllocatedFields) - static_cast<size_t>(nIndex) - 1) * sizeof(m_aryFields[0]));
        m_nFields--;
        return APE_ERROR_SUCCESS;
    }

    return APE_ERROR_UNDEFINED;
}

int CAPETag::RemoveField(const str_utfn * pFieldName)
{
    return RemoveField(GetTagFieldIndex(pFieldName));
}

int CAPETag::Remove(bool bUpdate)
{
    // variables
    int64 nBytesRead = 0;
    int nResult = 0;
    const int64 nOriginalPosition = m_spIO->GetPosition();

    bool bID3Removed = true;
    bool bAPETagRemoved = true;

    bool bFailedToRemove = false;

    while (bID3Removed || bAPETagRemoved)
    {
        bID3Removed = false;
        bAPETagRemoved = false;

        // ID3 tag
        if (m_bCheckForID3v1 && (m_spIO->GetSize() > ID3_TAG_BYTES))
        {
            m_spIO->Seek(-ID3_TAG_BYTES, SeekFileEnd);
            char cTagHeader[4];
            nResult = m_spIO->Read(cTagHeader, 3, &nBytesRead);
            cTagHeader[3] = 0; // null terminate
            if ((nResult == APE_ERROR_SUCCESS) && (nBytesRead == 3))
            {
                if (strncmp(cTagHeader, "TAG", 3) == 0)
                {
                    m_spIO->Seek(-ID3_TAG_BYTES, SeekFileEnd);
                    if (m_spIO->SetEOF() != 0)
                        bFailedToRemove = true;
                    else
                        bID3Removed = true;
                }
            }
        }

        // APE Tag
        if (m_spIO->GetSize() > APE_TAG_FOOTER_BYTES && !bFailedToRemove)
        {
            APE_TAG_FOOTER APETagFooter;
            m_spIO->Seek(-static_cast<int>(APE_TAG_FOOTER_BYTES), SeekFileEnd);
            APETagFooter.Empty();
            nResult = m_spIO->Read(&APETagFooter, APE_TAG_FOOTER_BYTES, & nBytesRead);
            if ((nResult == APE_ERROR_SUCCESS) && (nBytesRead == APE_TAG_FOOTER_BYTES))
            {
                if (APETagFooter.GetIsValid(true))
                {
                    m_spIO->Seek(-APETagFooter.GetTotalTagBytes(), SeekFileEnd);

                    if (m_spIO->SetEOF() != 0)
                        bFailedToRemove = true;
                    else
                        bAPETagRemoved = true;
                }
            }
        }
    }

    m_spIO->Seek(nOriginalPosition, SeekFileBegin);

    if (bUpdate && !bFailedToRemove)
    {
        Analyze();
    }

    return bFailedToRemove ? APE_ERROR_UNDEFINED : APE_ERROR_SUCCESS;
}

int CAPETag::SetFieldID3String(const str_utfn * pFieldName, const char * pFieldValue, int nBytes)
{
    // allocate a buffer and terminate it
    CSmartPtr<str_ansi> spBuffer(new str_ansi [static_cast<size_t>(nBytes) + 1], true);
    spBuffer[nBytes] = 0;

    // make a capped copy of the string
    memcpy(spBuffer.GetPtr(), pFieldValue, static_cast<size_t>(nBytes));

    // remove trailing white-space
    char * pEnd = &spBuffer[nBytes];
    while ((pEnd >= &spBuffer[0]) && ((*pEnd == ' ') || (*pEnd == 0))) { *pEnd-- = 0; }

    // set the field
    SetFieldString(pFieldName, spBuffer, false);

    return APE_ERROR_SUCCESS;
}

int CAPETag::GetFieldID3String(const str_utfn * pFieldName, char * pBuffer, int nBytes)
{
    int nBufferCharacters = 255; str_utfn cBuffer[256]; APE_CLEAR(cBuffer);
    GetFieldString(pFieldName, cBuffer, &nBufferCharacters);

    CSmartPtr<str_ansi> spBufferANSI(CAPECharacterHelper::GetANSIFromUTFN(cBuffer), true);

    memset(pBuffer, 0, static_cast<size_t>(nBytes));

    int nStringLength = static_cast<int>(strlen(spBufferANSI.GetPtr()));
    nStringLength = APE_MIN(nStringLength, nBytes);
    memcpy(pBuffer, spBufferANSI.GetPtr(), static_cast<size_t>(nStringLength));

    return APE_ERROR_SUCCESS;
}

int CAPETag::SortFields()
{
    // sort the tag fields by size (so that the smallest fields are at the front of the tag)
    if (m_nFields > 1)
        qsort(static_cast<void *>(m_aryFields), static_cast<size_t>(m_nFields), sizeof(m_aryFields[0]), CompareFields);

    return APE_ERROR_SUCCESS;
}

void CAPETag::SafeStringAppend(wchar_t * pDestination, size_t nDestinationSize, const wchar_t * pSource, bool & rbAppend)
{
    size_t nDestinationLength = wcslen(pDestination);
    if (rbAppend && ((wcslen(pSource) + nDestinationLength) < nDestinationSize))
    {
        wcscat_s(pDestination, nDestinationSize, pSource);
    }
    else
    {
        // we've filled the string up, so stop appending future values
        rbAppend = false;
    }
}

int CAPETag::CompareFields(const void * pA, const void * pB)
{
    const CAPETagField * pFieldA = *static_cast<const CAPETagField * const *>(pA);
    const CAPETagField * pFieldB = *static_cast<const CAPETagField * const *>(pB);

    int nValue = (pFieldA->GetFieldSize() - pFieldB->GetFieldSize());
    if (nValue == 0)
    {
        nValue = _wcsicmp(pFieldA->GetFieldName(), pFieldB->GetFieldName());
    }

    return nValue;
}

}
