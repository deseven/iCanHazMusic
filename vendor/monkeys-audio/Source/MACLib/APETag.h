#pragma once

/**************************************************************************************************
Include interfaces file
**************************************************************************************************/
#include "IAPETag.h"

namespace APE
{

class IAPEIO;

/**************************************************************************************************
APETag version history / supported formats

1.0 (1000) - Original APE tag spec. Fully supported by this code.
2.0 (2000) - Refined APE tag spec (better streaming support, UTF encoding). Fully supported by this code.

Notes:
    - also supports reading of ID3v1.1 tags
    - all saving done in the APE Tag format using CURRENT_APE_TAG_VERSION
**************************************************************************************************/

/**************************************************************************************************
APETag layout

1) Header - APE_TAG_FOOTER (optional) (32 bytes)
2) Fields (array):
        Value Size (4 bytes)
        Flags (4 bytes)
        Field Name (? ANSI bytes -- requires NULL terminator -- in range of 0x20 (space) to 0x7E (tilde))
        Value ([Value Size] bytes)
3) Footer - APE_TAG_FOOTER (32 bytes)
**************************************************************************************************/

/**************************************************************************************************
Notes

When saving images, store the extension in UTF-8, followed
by a null terminator, followed by the image data.

What saving text lists, delimit the values with a NULL terminator.
**************************************************************************************************/

/**************************************************************************************************
CAPETagField class (an APE tag is an array of these)
**************************************************************************************************/
class CAPETagField : public IAPETagField
{
public:
    // create a tag field (use nFieldBytes = -1 for null-terminated strings)
    CAPETagField(const str_utfn * pFieldName, const void * pFieldValue, int nFieldBytes = -1, int nFlags = 0);

    // destruction
    virtual ~CAPETagField() APE_OVERRIDE;

    // gets the size of the entire field in bytes (name, value, and metadata)
    int GetFieldSize() const APE_OVERRIDE;

    // get the name of the field
    const str_utfn * GetFieldName() const APE_OVERRIDE;

    // get the value of the field
    const char * GetFieldValue() APE_OVERRIDE;

    // get the size of the value (in bytes)
    int GetFieldValueSize() const APE_OVERRIDE;

    // get any special flags
    int GetFieldFlags() const APE_OVERRIDE;

    // checks to see if the field is read-only or UTF-8
    bool GetIsReadOnly() const APE_OVERRIDE;
    bool GetIsUTF8Text() const APE_OVERRIDE;

    // output the entire field to a buffer (GetFieldSize() bytes)
    int SaveField(char * pBuffer, int nBytes);

private:
    // helpers
    void Save32(char * pBuffer, int nValue);

    // data
    CSmartPtr<str_utfn> m_spFieldNameUTFN;
    CSmartPtr<char> m_spFieldValue;
    int m_nFieldFlags;
    int m_nFieldValueBytes;
};

/**************************************************************************************************
CAPETag class
**************************************************************************************************/
class CAPETag : public IAPETag
{
public:
    // create an APE tag
    // bAnalyze determines whether it will analyze immediately or on the first request
    // be careful with multiple threads / file pointer movement if you don't analyze immediately
    CAPETag(IAPEIO * pIO, bool bAnalyze = true, bool bCheckForID3v1 = true);
    CAPETag(const str_utfn * pFilename, bool bAnalyze = true);

    // destructor
    virtual ~CAPETag() APE_OVERRIDE;

    // save the tag to the I/O source (bUseOldID3 forces it to save as an ID3v1.1 tag instead of an APE tag)
    int Save(bool bUseOldID3 = false) APE_OVERRIDE;

    // removes any tags from the file (bUpdate determines whether is should re-analyze after removing the tag)
    int Remove(bool bUpdate = true) APE_OVERRIDE;

    // sets the value of a field (use nFieldBytes = -1 for null terminated strings)
    // note: using NULL or "" for a string type will remove the field
    int SetFieldString(const str_utfn * pFieldName, const str_utfn * pFieldValue, const str_utfn * pListDelimiter = APE_NULL) APE_OVERRIDE;
    int SetFieldString(const str_utfn * pFieldName, const char * pFieldValue, bool bAlreadyUTF8Encoded, const str_utfn * pListDelimiter = APE_NULL) APE_OVERRIDE;
    int SetFieldBinary(const str_utfn * pFieldName, const void * pFieldValue, intn nFieldBytes, int nFieldFlags) APE_OVERRIDE;

    // gets the value of a field (returns -1 and an empty buffer if the field doesn't exist)
    int GetFieldBinary(const str_utfn * pFieldName, void * pBuffer, int * pBufferBytes) APE_OVERRIDE;
    int GetFieldString(const str_utfn * pFieldName, str_utfn * pBuffer, int * pBufferCharacters, const str_utfn * pListDelimiter = L"; ") APE_OVERRIDE;
    int GetFieldString(const str_utfn * pFieldName, str_ansi * pBuffer, int * pBufferCharacters, bool bUTF8Encode = false) APE_OVERRIDE;
    int GetFieldNumber(const str_utfn * pFieldName, int nNotFoundResult = -1) APE_OVERRIDE;

    // remove a specific field
    int RemoveField(const str_utfn * pFieldName) APE_OVERRIDE;
    int RemoveField(int nIndex) APE_OVERRIDE;

    // clear all the fields
    int ClearFields() APE_OVERRIDE;

    // see if we've been analyzed (we do lazy analysis)
    bool GetAnalyzed() APE_OVERRIDE;

    // get the total tag bytes in the file from the last analyze
    // need to call Save() then Analyze() to update any changes
    int GetTagBytes() APE_OVERRIDE;

    // fills in an ID3_TAG using the current fields (useful for quickly converting the tag)
    int CreateID3Tag(ID3_TAG * pID3Tag) APE_OVERRIDE;

    // see whether the file has an ID3 or APE tag
    bool GetHasID3Tag() APE_OVERRIDE;
    bool GetHasAPETag() APE_OVERRIDE;
    int GetAPETagVersion() APE_OVERRIDE;
    bool GetIOMatches(IAPEIO * pIO) APE_OVERRIDE;

    // gets a desired tag field (returns NULL if not found)
    // again, be careful, because this a pointer to the actual field in this class
    IAPETagField * GetTagField(const str_utfn * pFieldName) APE_OVERRIDE;
    IAPETagField * GetTagField(int nIndex) APE_OVERRIDE;

    // options
    void SetIgnoreReadOnly(bool bIgnoreReadOnly) APE_OVERRIDE;

    // output the tag for display
    int OutputTag(str_utfn * pOutput, int nOutputLength) APE_OVERRIDE;

    // statics
    static const int s_nID3GenreUndefined = 255;
    static const int s_nID3GenreCount = 148;
    static const str_utfn * s_aryID3GenreNames[s_nID3GenreCount];

private:
    // private functions
    int Analyze();
    int GetTagFieldIndex(const str_utfn * pFieldName);
    int WriteBufferToEndOfIO(void * pBuffer, int nBytes);
    int LoadField(const char * pBuffer, int nMaximumBytes, int * pBytes);
    int SortFields();
    void SafeStringAppend(wchar_t * pDestination, size_t nDestinationSize, const wchar_t * pSource, bool & rbAppend);
    static int CompareFields(const void * pA, const void * pB);

    // helper set / get field functions
    int SetFieldID3String(const str_utfn * pFieldName, const char * pFieldValue, int nBytes);
    int GetFieldID3String(const str_utfn * pFieldName, char * pBuffer, int nBytes);

    // private data
    CSmartPtr<IAPEIO> m_spIO;
    int m_nTagBytes;
    int m_nAPETagVersion;
    int m_nFields;
    int m_nAllocatedFields;
    CAPETagField ** m_aryFields;
    bool m_bAnalyzed;
    bool m_bHasAPETag;
    bool m_bHasID3Tag;
    bool m_bIgnoreReadOnly;
    bool m_bCheckForID3v1;
};

}
