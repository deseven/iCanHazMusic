// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A plain C interface to the Monkey's Audio decoder (the SDK is C++), so Swift needs no C++ interop.
// Not part of the SDK: this and ichm_ape.cpp are ours.
//
// - The file is read through `ichm_ape_reader`, i.e. by the caller's code, never by the SDK's own file I/O.
// - No C++ exception gets out: every call catches them and reports an error.
// - A decoder is not thread-safe; use one from one thread at a time.

#ifndef ICHM_APE_H
#define ICHM_APE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Where the bytes come from. `read_at` reads up to `count` bytes at `offset` into `buffer` and returns how many it
/// read (0 at the end of the file), or -1 on an error. `size` is the length of the file in bytes, -1 if unknown.
typedef struct {
    void *context;
    int64_t (*read_at)(void *context, int64_t offset, void *buffer, int64_t count);
    int64_t size;
} ichm_ape_reader;

typedef struct ichm_ape_decoder ichm_ape_decoder;

typedef struct {
    int32_t sample_rate;
    int32_t channels;
    /// 8, 16, 24 or 32. Samples come out as integers of `bits_per_sample / 8` bytes, little-endian, interleaved;
    /// 8 bit ones unsigned (offset 128). With `is_float` they are 32 bit IEEE floats.
    int32_t bits_per_sample;
    int32_t is_float;
    /// Length in frames ("blocks").
    int64_t total_frames;
    /// File version * 1000 (3990 = 3.99), compression level (1000 fast ... 5000 insane), average bit rate in kbit/s.
    int32_t file_version;
    int32_t compression_level;
    int32_t average_bitrate;
    /// The speaker positions of the original WAV file (`dwChannelMask` of its WAVEFORMATEXTENSIBLE header: bit 0 front
    /// left, 1 front right, 2 front centre, 3 LFE, ...), 0 if the file has none stored (the usual case for mono and
    /// stereo).
    uint32_t channel_mask;
} ichm_ape_info;

/// Opens a decoder that reads through `reader` (copied; its context must outlive the decoder). NULL on failure, with
/// the SDK's error code in `error` (if given).
ichm_ape_decoder *ichm_ape_open(const ichm_ape_reader *reader, int32_t *error);

void ichm_ape_get_info(ichm_ape_decoder *decoder, ichm_ape_info *info);

/// Decodes up to `frames` frames into `buffer` (room for `frames * channels * bits_per_sample / 8` bytes). Returns the
/// number of frames decoded (0 at the end), or -1 on an error (a damaged file: the SDK fills what follows the damage
/// with silence, so nothing of that call is handed out).
int64_t ichm_ape_read(ichm_ape_decoder *decoder, void *buffer, int64_t frames);

/// Positions the decoder at `frame` (exact). 0 on success, the SDK's error code otherwise.
int32_t ichm_ape_seek(ichm_ape_decoder *decoder, int64_t frame);

void ichm_ape_close(ichm_ape_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
