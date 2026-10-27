#pragma once

/**************************************************************************************************
IAPETag.h - define the APE tag interfaces so APETag.h doesn't need to get included.
**************************************************************************************************/
namespace APE
{

/**************************************************************************************************
Forward declares
**************************************************************************************************/
class IAPEIO;

/**************************************************************************************************
ID3 v1.1 tag
**************************************************************************************************/
#define ID3_TAG_BYTES 128 // equal to sizeof(ID3_TAG)
#pragma pack(push, 1)
struct ID3_TAG
{
    char Header[3];             // should equal 'TAG'
    char Title[30];             // title
    char Artist[30];            // artist
    char Album[30];             // album
    char Year[4];               // year
    char Comment[29];           // comment
    unsigned char Track;        // track
    unsigned char Genre;        // genre
};
#pragma pack(pop)

/**************************************************************************************************
IAPETagField interface
**************************************************************************************************/
class IAPETagField
{
public:
    // destruction
    virtual ~IAPETagField() { }

    // gets the size of the entire field in bytes (name, value, and metadata)
    virtual int GetFieldSize() const = 0;

    // get the name of the field
    virtual const str_utfn * GetFieldName() const = 0;

    // get the value of the field
    virtual const char * GetFieldValue() = 0;

    // get the size of the value (in bytes)
    virtual int GetFieldValueSize() const = 0;

    // get any special flags
    virtual int GetFieldFlags() const = 0;

    // checks to see if the field is read-only or UTF-8
    virtual bool GetIsReadOnly() const = 0;
    virtual bool GetIsUTF8Text() const = 0;
};

/**************************************************************************************************
IAPETag interface
**************************************************************************************************/
class IAPETag
{
public:
    virtual ~IAPETag() { }

    // save the tag to the I/O source (bUseOldID3 forces it to save as an ID3v1.1 tag instead of an APE tag)
    virtual int Save(bool bUseOldID3 = false) = 0;

    // removes any tags from the file (bUpdate determines whether is should re-analyze after removing the tag)
    virtual int Remove(bool bUpdate = true) = 0;

    // sets the value of a field (use nFieldBytes = -1 for null terminated strings)
    // note: using NULL or "" for a string type will remove the field
    virtual int SetFieldString(const str_utfn * pFieldName, const str_utfn * pFieldValue, const str_utfn * pListDelimiter = APE_NULL) = 0;
    virtual int SetFieldString(const str_utfn * pFieldName, const char * pFieldValue, bool bAlreadyUTF8Encoded, const str_utfn * pListDelimiter = APE_NULL) = 0;
    virtual int SetFieldBinary(const str_utfn * pFieldName, const void * pFieldValue, intn nFieldBytes, int nFieldFlags) = 0;

    // gets the value of a field (returns -1 and an empty buffer if the field doesn't exist)
    virtual int GetFieldBinary(const str_utfn * pFieldName, void * pBuffer, int * pBufferBytes) = 0;
    virtual int GetFieldString(const str_utfn * pFieldName, str_utfn * pBuffer, int * pBufferCharacters, const str_utfn * pListDelimiter = L"; ") = 0;
    virtual int GetFieldString(const str_utfn * pFieldName, str_ansi * pBuffer, int * pBufferCharacters, bool bUTF8Encode = false) = 0;
    virtual int GetFieldNumber(const str_utfn * pFieldName, int nNotFoundResult = -1) = 0;

    // remove a specific field
    virtual int RemoveField(const str_utfn * pFieldName) = 0;
    virtual int RemoveField(int nIndex) = 0;

    // clear all the fields
    virtual int ClearFields() = 0;

    // see if we've been analyzed (we do lazy analysis)
    virtual bool GetAnalyzed() = 0;

    // get the total tag bytes in the file from the last analyze
    // need to call Save() then Analyze() to update any changes
    virtual int GetTagBytes() = 0;

    // fills in an ID3_TAG using the current fields (useful for quickly converting the tag)
    virtual int CreateID3Tag(ID3_TAG * pID3Tag) = 0;

    // see whether the file has an ID3 or APE tag
    virtual bool GetHasID3Tag() = 0;
    virtual bool GetHasAPETag() = 0;
    virtual int GetAPETagVersion() = 0;
    virtual bool GetIOMatches(IAPEIO * pIO) = 0;

    // gets a desired tag field (returns NULL if not found)
    // again, be careful, because this a pointer to the actual field in this class
    virtual IAPETagField * GetTagField(const str_utfn * pFieldName) = 0;
    virtual IAPETagField * GetTagField(int nIndex) = 0;

    // options
    virtual void SetIgnoreReadOnly(bool bIgnoreReadOnly) = 0;

    // output the tag for display
    virtual int OutputTag(str_utfn * pOutput, int nOutputLength) = 0;
};

/**************************************************************************************************
The version of the APE tag
**************************************************************************************************/
#define CURRENT_APE_TAG_VERSION                 2000

/**************************************************************************************************
The footer at the end of APE tagged files (can also optionally be at the front of the tag)
**************************************************************************************************/
#define APE_TAG_FOOTER_BYTES    32

/**************************************************************************************************
Footer (and header) flags
**************************************************************************************************/
#define APE_TAG_FLAG_CONTAINS_HEADER            (static_cast<unsigned int>(1) << 31)
#define APE_TAG_FLAG_CONTAINS_FOOTER            (1 << 30)
#define APE_TAG_FLAG_IS_HEADER                  (1 << 29)

#define APE_TAG_FLAGS_DEFAULT                   (APE_TAG_FLAG_CONTAINS_FOOTER)

/**************************************************************************************************
Tag field flags
**************************************************************************************************/
#define TAG_FIELD_FLAG_READ_ONLY                (1 << 0)

#define TAG_FIELD_FLAG_DATA_TYPE_MASK           (6)
#define TAG_FIELD_FLAG_DATA_TYPE_TEXT_UTF8      (0 << 1)
#define TAG_FIELD_FLAG_DATA_TYPE_BINARY         (1 << 1)
#define TAG_FIELD_FLAG_DATA_TYPE_EXTERNAL_INFO  (2 << 1)
#define TAG_FIELD_FLAG_DATA_TYPE_RESERVED       (3 << 1)

/**************************************************************************************************
APE_TAG_FOOTER
**************************************************************************************************/
class APE_TAG_FOOTER
{
protected:
    char m_cID[8];              // should equal 'APETAGEX'
    int m_nVersion;             // equals CURRENT_APE_TAG_VERSION
    int m_nSize;                // the complete size of the tag, including this footer (excludes header)
    int m_nFields;              // the number of fields in the tag
    int m_nFlags;               // the tag flags
    char m_cReserved[8];        // reserved for later use (must be zero)

public:
    APE_TAG_FOOTER(int nFields = 0, int nFieldBytes = 0)
    {
        memcpy(m_cID, "APETAGEX", 8);
        APE_CLEAR(m_cReserved);
        m_nFields = nFields;
        m_nFlags = APE_TAG_FLAGS_DEFAULT;
        m_nSize = nFieldBytes + APE_TAG_FOOTER_BYTES;
        m_nVersion = CURRENT_APE_TAG_VERSION;
    }

    APE_INLINE int GetTotalTagBytes() const { return m_nSize + (GetHasHeader() ? APE_TAG_FOOTER_BYTES : 0); }
    APE_INLINE int GetFieldBytes() const { return m_nSize - APE_TAG_FOOTER_BYTES; }
    APE_INLINE int GetFieldsOffset() const { return GetHasHeader() ? APE_TAG_FOOTER_BYTES : 0; }
    APE_INLINE int GetNumberFields() const { return m_nFields; }
    APE_INLINE bool GetHasHeader() const { return (static_cast<unsigned int>(m_nFlags) & APE_TAG_FLAG_CONTAINS_HEADER) ? true : false; }
    APE_INLINE bool GetIsHeader() const { return (static_cast<unsigned int>(m_nFlags) & APE_TAG_FLAG_IS_HEADER) ? true : false; }
    APE_INLINE int GetVersion() const { return m_nVersion; }
    APE_INLINE void Empty() { APE_CLEAR(m_cID); }
    APE_INLINE bool GetIsValid(bool bAllowHeader) const
    {
        bool bValid = (strncmp(m_cID, "APETAGEX", 8) == 0) &&
            (m_nVersion <= CURRENT_APE_TAG_VERSION) &&
            (m_nFields <= 65536) &&
            (m_nSize >= APE_TAG_FOOTER_BYTES) &&
            (GetFieldBytes() <= (APE_BYTES_IN_MEGABYTE * 256));

        if (bValid && !bAllowHeader && GetIsHeader())
            bValid = false;

        return bValid ? true : false;
    }
};

/**************************************************************************************************
"Standard" APE tag fields
**************************************************************************************************/
#define APE_TAG_FIELD_TITLE                     L"Title"
#define APE_TAG_FIELD_ARTIST                    L"Artist"
#define APE_TAG_FIELD_ALBUM                     L"Album"
#define APE_TAG_FIELD_ALBUM_ARTIST              L"Album Artist"
#define APE_TAG_FIELD_COMMENT                   L"Comment"
#define APE_TAG_FIELD_YEAR                      L"Year"
#define APE_TAG_FIELD_TRACK                     L"Track"
#define APE_TAG_FIELD_DISC                      L"Disc"
#define APE_TAG_FIELD_GENRE                     L"Genre"
#define APE_TAG_FIELD_COVER_ART_FRONT           L"Cover Art (front)" // stored as binary [extension][NULL character][image data] - previously was [filename] instead of [extension] so check for a dot when reading
#define APE_TAG_FIELD_NOTES                     L"Notes"
#define APE_TAG_FIELD_LYRICS                    L"Lyrics"
#define APE_TAG_FIELD_COPYRIGHT                 L"Copyright"
#define APE_TAG_FIELD_BUY_URL                   L"Buy URL"
#define APE_TAG_FIELD_ARTIST_URL                L"Artist URL"
#define APE_TAG_FIELD_PUBLISHER_URL             L"Publisher URL"
#define APE_TAG_FIELD_FILE_URL                  L"File URL"
#define APE_TAG_FIELD_COPYRIGHT_URL             L"Copyright URL"
#define APE_TAG_FIELD_TOOL_NAME                 L"Tool Name"
#define APE_TAG_FIELD_TOOL_VERSION              L"Tool Version"
#define APE_TAG_FIELD_PEAK_LEVEL                L"Peak Level"
#define APE_TAG_FIELD_REPLAY_GAIN_RADIO         L"Replay Gain (radio)"
#define APE_TAG_FIELD_REPLAY_GAIN_ALBUM         L"Replay Gain (album)"
#define APE_TAG_FIELD_COMPOSER                  L"Composer"
#define APE_TAG_FIELD_CONDUCTOR                 L"Conductor"
#define APE_TAG_FIELD_ORCHESTRA                 L"Orchestra"
#define APE_TAG_FIELD_KEYWORDS                  L"Keywords"
#define APE_TAG_FIELD_RATING                    L"Rating"
#define APE_TAG_FIELD_PUBLISHER                 L"Publisher"
#define APE_TAG_FIELD_BPM                       L"BPM"

/**************************************************************************************************
Standard APE tag field values
**************************************************************************************************/
#define APE_TAG_GENRE_UNDEFINED                 L"Undefined"

}
