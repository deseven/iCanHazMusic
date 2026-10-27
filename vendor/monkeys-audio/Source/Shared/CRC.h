#pragma once

// If target platform supports hardware optimized CRC32 calculation, define the following:
//
// 1) ARMv8 with CRC32 instructions:
//#define ENABLE_ARM_CRC32_OPT

namespace APE
{

uint32 CRC_update(uint32 crc, const unsigned char * pData, int nBytes);

}
