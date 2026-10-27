#include "All.h"
#include "APELink.h"
#include "CharacterHelper.h"
#include "IAPEIO.h"
#include "MACLib.h"

namespace APE
{

#define APE_LINK_HEADER                 "[Monkey's Audio Image Link File]"
#define APE_LINK_IMAGE_FILE_TAG         "Image File="
#define APE_LINK_START_BLOCK_TAG        "Start Block="
#define APE_LINK_FINISH_BLOCK_TAG       "Finish Block="

CAPELink::CAPELink(const str_utfn * pFilename)
{
    // empty
    m_bIsLinkFile = false;
    m_nStartBlock = 0;
    m_nFinishBlock = 0;
    m_cImageFilename[0] = 0;

    // open the file
    CSmartPtr<IAPEIO> spioLinkFile(CreateIAPEIO());
    if (spioLinkFile->Open(pFilename) == APE_ERROR_SUCCESS)
    {
        // create a buffer
        CSmartPtr<char> spBuffer(new char [4097], true);

        // fill the buffer from the file and null terminate it
        // we read enough to get all the data at the front (the tag follows which could be big)
        // this might read less if the file is shorter, but that's fine
        int64 nBytesRead = 0;
        spioLinkFile->Read(spBuffer.GetPtr(), 4096, &nBytesRead);
        spBuffer[nBytesRead] = 0;

        // call the other constructor (uses a buffer instead of opening the file)
        ParseData(spBuffer, pFilename);
    }
}

CAPELink::CAPELink(const char * pData, const str_utfn * pFilename)
{
    ParseData(pData, pFilename);
}

CAPELink::~CAPELink()
{
}

void CAPELink::ParseData(const char * pData, const str_utfn * pFilename)
{
    // empty
    m_bIsLinkFile = false;
    m_nStartBlock = 0;
    m_nFinishBlock = 0;
    m_cImageFilename[0] = 0;

    if (pData != APE_NULL)
    {
        // parse out the information
        const char * pHeader = static_cast<const char *>(strstr(pData, APE_LINK_HEADER));
        const char * pImageFile = static_cast<const char *>(strstr(pData, APE_LINK_IMAGE_FILE_TAG));
        const char * pStartBlock = static_cast<const char *>(strstr(pData, APE_LINK_START_BLOCK_TAG));
        const char * pFinishBlock = static_cast<const char *>(strstr(pData, APE_LINK_FINISH_BLOCK_TAG));

        if (pHeader && pImageFile && pStartBlock && pFinishBlock)
        {
            if ((_strnicmp(pHeader, APE_LINK_HEADER, strlen(APE_LINK_HEADER)) == 0) &&
                (_strnicmp(pImageFile, APE_LINK_IMAGE_FILE_TAG, strlen(APE_LINK_IMAGE_FILE_TAG)) == 0) &&
                (_strnicmp(pStartBlock, APE_LINK_START_BLOCK_TAG, strlen(APE_LINK_START_BLOCK_TAG)) == 0) &&
                (_strnicmp(pFinishBlock, APE_LINK_FINISH_BLOCK_TAG, strlen(APE_LINK_FINISH_BLOCK_TAG)) == 0))
            {
                // get the start and finish blocks
                m_nStartBlock = atoi(&pStartBlock[strlen(APE_LINK_START_BLOCK_TAG)]);
                m_nFinishBlock = atoi(&pFinishBlock[strlen(APE_LINK_FINISH_BLOCK_TAG)]);

                // get the path
                char cImageFile[MAX_PATH + 1] = { 0 }; int nIndex = 0;
                const char * pImageCharacter = &pImageFile[strlen(APE_LINK_IMAGE_FILE_TAG)];
                while ((*pImageCharacter != 0) && (*pImageCharacter != '\r') && (*pImageCharacter != '\n'))
                    cImageFile[nIndex++] = *pImageCharacter++;
                cImageFile[nIndex] = 0;

                CSmartPtr<str_utfn> spImageFileUTFN(CAPECharacterHelper::GetUTFNFromUTF8(reinterpret_cast<const str_utf8 *>(cImageFile)), true);

                // process the path
                if ((wcsrchr(spImageFileUTFN, APE_FILENAME_SLASH) == APE_NULL) && (wcsrchr(pFilename, APE_FILENAME_SLASH) != APE_NULL))
                {
                    str_utfn cImagePath[MAX_PATH + 1];
                    wcscpy_s(cImagePath, MAX_PATH, pFilename);
                    str_utfn * pNext = wcsrchr(cImagePath, APE_FILENAME_SLASH) + 1;
                    wcscpy_s(pNext, static_cast<size_t>(MAX_PATH - (pNext - cImagePath)), spImageFileUTFN);
                    wcscpy_s(m_cImageFilename, MAX_PATH, cImagePath);
                }
                else
                {
                    wcscpy_s(m_cImageFilename, MAX_PATH, spImageFileUTFN);
                }

                // this is a valid link file
                m_bIsLinkFile = true;
            }
        }
    }
}

int CAPELink::GetStartBlock() const
{
    return m_nStartBlock;
}

int CAPELink::GetFinishBlock() const
{
    return m_nFinishBlock;
}

const str_utfn * CAPELink::GetImageFilename()
{
    return m_cImageFilename;
}

bool CAPELink::GetIsLinkFile() const
{
    return m_bIsLinkFile;
}

}
