// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstring>
#include <vector>

#include "All.h"
#include "MACLib.h"
#include "IAPEIO.h"
#include "ichm_ape.h"

using namespace APE;

namespace {

uint32_t readLE32(const unsigned char *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}

/// `dwChannelMask` of the WAV header the file was made from: 0 if there is none, or the header has no extensible
/// format chunk (a plain mono or stereo file, whose header the SDK makes up).
uint32_t storedChannelMask(IAPEDecompress *decompress) {
    const int64 bytes = decompress->GetInfo(IAPEInfo::APE_INFO_WAV_HEADER_BYTES);
    if (bytes < 12 + 8 + 40 || bytes > 4096) return 0;
    std::vector<unsigned char> header(static_cast<size_t>(bytes));
    if (decompress->GetInfo(IAPEInfo::APE_INFO_WAV_HEADER_DATA, APE_POINTER_TO_INT64(header.data()), bytes)
        != APE_ERROR_SUCCESS) return 0;

    // "RIFF" (or "RF64"), a size, "WAVE", then chunks: id, size, data.
    size_t at = 12;
    while (at + 8 <= header.size()) {
        const uint32_t size = readLE32(&header[at + 4]);
        if (std::memcmp(&header[at], "fmt ", 4) == 0) {
            // WAVEFORMATEXTENSIBLE: tag (0xFFFE), channels, rate, bytes/s, align, bits, cbSize (>= 22), valid
            // bits, channel mask, sub format.
            const size_t body = at + 8;
            if (size < 40 || body + 24 > header.size()) return 0;
            const unsigned tag = header[body] | header[body + 1] << 8;
            const unsigned extra = header[body + 16] | header[body + 17] << 8;
            return (tag == WAVE_FORMAT_EXTENSIBLE && extra >= 22) ? readLE32(&header[body + 20]) : 0;
        }
        at += 8 + size + (size & 1);
    }
    return 0;
}

/// The SDK's I/O interface over the caller's reader: read-only, positioned reads.
class ReaderIO final : public IAPEIO {
public:
    explicit ReaderIO(const ichm_ape_reader &reader) : m_reader(reader) {}

    int Open(const str_utfn *, bool) override { return APE_ERROR_IO_READ; }
    int Close() override { return APE_ERROR_SUCCESS; }

    int Read(void *pBuffer, int64 nBytesToRead, int64 *pBytesRead) override {
        int64 total = 0;
        auto *out = static_cast<unsigned char *>(pBuffer);
        while (total < nBytesToRead) {
            const int64 got = m_reader.read_at(m_reader.context, m_position, out + total, nBytesToRead - total);
            if (got < 0) {
                if (pBytesRead) *pBytesRead = total;
                return APE_ERROR_IO_READ;
            }
            if (got == 0) break;
            total += got;
            m_position += got;
        }
        if (pBytesRead) *pBytesRead = total;
        // The same as the SDK's own file I/O: reading nothing at all is an error, a short read is not.
        return (total == 0 && nBytesToRead > 0) ? APE_ERROR_IO_READ : APE_ERROR_SUCCESS;
    }

    int Write(const void *, int64, int64 *pBytesWritten) override {
        if (pBytesWritten) *pBytesWritten = 0;
        return APE_ERROR_IO_WRITE;
    }

    int Seek(int64 nPosition, SeekMethod nMethod) override {
        int64 base = 0;
        switch (nMethod) {
        case SeekFileBegin: base = 0; break;
        case SeekFileCurrent: base = m_position; break;
        case SeekFileEnd:
            if (m_reader.size < 0) return APE_ERROR_IO_READ;
            base = m_reader.size;
            break;
        }
        if (base + nPosition < 0) return APE_ERROR_IO_READ;
        m_position = base + nPosition;
        return APE_ERROR_SUCCESS;
    }

    int Create(const str_utfn *) override { return APE_ERROR_IO_WRITE; }
    int Delete() override { return APE_ERROR_IO_WRITE; }
    int SetEOF() override { return APE_ERROR_IO_WRITE; }
    unsigned char *GetBuffer(int *pnBufferBytes) override {
        if (pnBufferBytes) *pnBufferBytes = 0;
        return APE_NULL;
    }
    int64 GetPosition() override { return m_position; }
    int64 GetSize() override { return m_reader.size < 0 ? APE_FILE_SIZE_UNDEFINED : m_reader.size; }

private:
    ichm_ape_reader m_reader;
    int64 m_position = 0;
};

} // namespace

struct ichm_ape_decoder {
    // The decompressor refers to the I/O object without owning it: `io` is destroyed after it.
    ReaderIO *io;
    IAPEDecompress *decompress;
    int channels;
    int bytesPerSample;
};

extern "C" ichm_ape_decoder *ichm_ape_open(const ichm_ape_reader *reader, int32_t *error) {
    if (error) *error = APE_ERROR_UNDEFINED;
    if (reader == nullptr || reader->read_at == nullptr) return nullptr;
    ReaderIO *io = nullptr;
    try {
        io = new ReaderIO(*reader);
        int code = APE_ERROR_UNDEFINED;
        IAPEDecompress *decompress = CreateIAPEDecompressEx(io, &code);
        if (decompress == nullptr || code != APE_ERROR_SUCCESS) {
            delete decompress;
            delete io;
            if (error) *error = code == APE_ERROR_SUCCESS ? APE_ERROR_UNDEFINED : code;
            return nullptr;
        }
        const int channels = static_cast<int>(decompress->GetInfo(IAPEInfo::APE_INFO_CHANNELS));
        const int bits = static_cast<int>(decompress->GetInfo(IAPEInfo::APE_INFO_BITS_PER_SAMPLE));
        if (channels <= 0 || bits <= 0 || bits % 8 != 0) {
            delete decompress;
            delete io;
            if (error) *error = APE_ERROR_INVALID_INPUT_FILE;
            return nullptr;
        }
        if (error) *error = APE_ERROR_SUCCESS;
        return new ichm_ape_decoder { io, decompress, channels, bits / 8 };
    } catch (...) {
        delete io;
        if (error) *error = APE_ERROR_UNDEFINED;
        return nullptr;
    }
}

extern "C" void ichm_ape_get_info(ichm_ape_decoder *decoder, ichm_ape_info *info) {
    *info = ichm_ape_info {};
    try {
        IAPEDecompress *d = decoder->decompress;
        info->sample_rate = static_cast<int32_t>(d->GetInfo(IAPEInfo::APE_INFO_SAMPLE_RATE));
        info->channels = decoder->channels;
        info->bits_per_sample = decoder->bytesPerSample * 8;
        info->is_float = (d->GetInfo(IAPEInfo::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_FLOATING_POINT) ? 1 : 0;
        info->total_frames = d->GetInfo(IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS);
        info->file_version = static_cast<int32_t>(d->GetInfo(IAPEInfo::APE_INFO_FILE_VERSION));
        info->compression_level = static_cast<int32_t>(d->GetInfo(IAPEInfo::APE_INFO_COMPRESSION_LEVEL));
        info->average_bitrate = static_cast<int32_t>(d->GetInfo(IAPEInfo::APE_INFO_AVERAGE_BITRATE));
        info->channel_mask = storedChannelMask(d);
    } catch (...) {
    }
}

extern "C" int64_t ichm_ape_read(ichm_ape_decoder *decoder, void *buffer, int64_t frames) {
    try {
        // Floats are restored. The other two would turn the samples back into the layout of the file that was
        // compressed (signed 8 bit, big-endian for an AIFF), the documented layout is the decoder's own (WAV's).
        IAPEDecompress::APE_GET_DATA_PROCESSING processing { true, false, false };
        int64 got = 0;
        const int result = decoder->decompress->GetData(static_cast<unsigned char *>(buffer), frames, &got, &processing);
        return result == APE_ERROR_SUCCESS ? got : -1;
    } catch (...) {
        return -1;
    }
}

extern "C" int32_t ichm_ape_seek(ichm_ape_decoder *decoder, int64_t frame) {
    try {
        return decoder->decompress->Seek(frame);
    } catch (...) {
        return APE_ERROR_UNDEFINED;
    }
}

extern "C" void ichm_ape_close(ichm_ape_decoder *decoder) {
    if (decoder == nullptr) return;
    try {
        delete decoder->decompress;
    } catch (...) {
    }
    delete decoder->io;
    delete decoder;
}
