/*
 * Copyright (C) 1991-2, RSA Data Security, Inc. Created 1991. All
 * rights reserved.
 *
 * License to copy and use this software is granted provided that it
 * is identified as the "RSA Data Security, Inc. MD5 Message-Digest
 * Algorithm" in all material mentioning or referencing this software
 * or this function.
 *
 * License is also granted to make and use derivative works provided
 * that such works are identified as "derived from the RSA Data
 * Security, Inc. MD5 Message-Digest Algorithm" in all material
 * mentioning or referencing the derived work.
 *
 * RSA Data Security, Inc. makes no representations concerning either
 * the merchantability of this software or the suitability of this
 * software for any particular purpose. It is provided "as is"
 * without express or implied warranty of any kind.
 *
 * These notices must be retained in any copies of any part of this
 * documentation and/or software.
 */

#pragma once

#include "All.h"

#define MD5_BLOCK_LENGTH            64
#define MD5_DIGEST_LENGTH           16
#define MD5_DIGEST_STRING_LENGTH    (MD5_DIGEST_LENGTH * 2 + 1)

/* MD5 context. */
typedef struct MD5Context {
    uint32_t state[4];    /* state (ABCD) */
    uint32_t count[2];    /* number of bits, modulo 2^64 (lsb first) */
    unsigned char buffer[64];    /* input buffer */
} MD5_CTX;

//__BEGIN_DECLS
void   MD5Init (MD5_CTX *);
void   MD5Update (MD5_CTX *, const void *, unsigned int);
void   MD5Final (unsigned char [16], MD5_CTX *);
char * MD5End(MD5_CTX *, char *);
char * MD5File(const char *, char *);
char * MD5FileChunk(const char *, char *, off_t, off_t);
char * MD5Data(const void *, unsigned int, char *);
//__END_DECLS

/**************************************************************************************************
CMD5Helper
**************************************************************************************************/
class CMD5Helper
{
public:
    CMD5Helper()
    {
        MD5Init(&m_MD5Context);
    }

    APE_INLINE void AddData(const void * pData, APE::int64 nBytes)
    {
        MD5Update(&m_MD5Context, static_cast<const unsigned char *>(pData), static_cast<unsigned int>(nBytes));
    }

    bool GetResult(unsigned char cResult[16])
    {
        MD5Final(cResult, &m_MD5Context);
        return true;
    }

protected:
    MD5_CTX m_MD5Context;
};
