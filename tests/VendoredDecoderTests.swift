// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CMonkeysAudio
import CWavPack
import Darwin
import Foundation
import Testing
@testable import iCanHazMusic

/// The decoders in `vendor/` work as compiled into the package: a file is read through our own callbacks (as the app
/// will do it, see `dev-docs/extra-formats-support.md`), decoded sample by sample and seeked exactly. Not app code yet.
extension AllTests {
    @MainActor @Suite("Vendored decoders")
    struct VendoredDecoderTests {
        /// A file read with `pread`, the context both readers get.
        private final class OpenFile {
            let fd: Int32
            let size: Int64
            /// WavPack's reader keeps a position and can push one byte back.
            var position: Int64 = 0
            var pushedBack: Int32 = -1

            init?(_ url: URL) {
                fd = open(url.path, O_RDONLY)
                guard fd >= 0 else { return nil }
                var info = stat()
                size = fstat(fd, &info) == 0 ? Int64(info.st_size) : -1
            }

            deinit { close(fd) }

            func read(at offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
                pread(fd, buffer, count, off_t(offset))
            }

            static func from(_ pointer: UnsafeMutableRawPointer?) -> OpenFile {
                Unmanaged<OpenFile>.fromOpaque(pointer!).takeUnretainedValue()
            }
        }

        /// What was decoded: integer samples scaled to -1...1, both channels.
        private struct Decoded {
            var frames: Int64 = 0
            var samples: [[Float]] = [[], []]
            var failure: String?
        }

        // MARK: WavPack

        private static func wavPackReader() -> WavpackStreamReader64 {
            WavpackStreamReader64(
                read_bytes: { id, data, count in
                    let file = OpenFile.from(id)
                    guard let data, count > 0 else { return 0 }
                    var out = data
                    var done: Int32 = 0
                    if file.pushedBack >= 0 {
                        out.storeBytes(of: UInt8(file.pushedBack), as: UInt8.self)
                        file.pushedBack = -1
                        file.position += 1
                        out += 1
                        done = 1
                    }
                    let got = file.read(at: file.position, into: out, count: Int(count - done))
                    if got > 0 {
                        file.position += Int64(got)
                        done += Int32(got)
                    }
                    return done
                },
                write_bytes: nil,
                get_pos: { id in
                    let file = OpenFile.from(id)
                    return file.position
                },
                set_pos_abs: { id, position in
                    let file = OpenFile.from(id)
                    file.pushedBack = -1
                    file.position = position
                    return 0
                },
                set_pos_rel: { id, delta, mode in
                    let file = OpenFile.from(id)
                    file.pushedBack = -1
                    switch mode {
                    case SEEK_SET: file.position = delta
                    case SEEK_CUR: file.position += delta
                    case SEEK_END: file.position = file.size + delta
                    default: return -1
                    }
                    return 0
                },
                push_back_byte: { id, byte in
                    let file = OpenFile.from(id)
                    file.position -= 1
                    file.pushedBack = byte
                    return byte
                },
                get_length: { id in
                    let file = OpenFile.from(id)
                    return file.size
                },
                can_seek: { _ in 1 },
                truncate_here: nil,
                close: nil
            )
        }

        private func decodeWavPack(_ url: URL, from start: Int64 = 0) -> Decoded {
            var result = Decoded()
            guard let file = OpenFile(url) else { result.failure = "can't open"; return result }
            let reader = UnsafeMutablePointer<WavpackStreamReader64>.allocate(capacity: 1)
            reader.initialize(to: Self.wavPackReader())
            defer { reader.deallocate() }
            var error = [CChar](repeating: 0, count: 81)
            guard let context = WavpackOpenFileInputEx64(reader, Unmanaged.passUnretained(file).toOpaque(), nil, &error,
                                                         OPEN_TAGS | OPEN_NORMALIZE, 0) else {
                result.failure = String(cString: error)
                return result
            }
            defer { WavpackCloseFile(context) }

            result.frames = WavpackGetNumSamples64(context)
            let channels = Int(WavpackGetNumChannels(context))
            let scale = Float(1 << (WavpackGetBitsPerSample(context) - 1))
            if start > 0, WavpackSeekSample64(context, start) == 0 {
                result.failure = "seek failed"
                return result
            }
            var buffer = [Int32](repeating: 0, count: 4096 * channels)
            while true {
                let got = Int(WavpackUnpackSamples(context, &buffer, 4096))
                if got == 0 { break }
                for i in 0..<got {
                    for channel in 0..<2 { result.samples[channel].append(Float(buffer[i * channels + channel]) / scale) }
                }
            }
            return result
        }

        // MARK: Monkey's Audio

        private func decodeAPE(_ url: URL, from start: Int64 = 0) -> Decoded {
            var result = Decoded()
            guard let file = OpenFile(url) else { result.failure = "can't open"; return result }
            var reader = ichm_ape_reader(
                context: Unmanaged.passUnretained(file).toOpaque(),
                read_at: { context, offset, buffer, count in
                    guard let buffer else { return -1 }
                    return Int64(OpenFile.from(context).read(at: offset, into: buffer, count: Int(count)))
                },
                size: file.size)
            var error: Int32 = 0
            guard let decoder = ichm_ape_open(&reader, &error) else {
                result.failure = "error \(error)"
                return result
            }
            defer { ichm_ape_close(decoder) }

            var info = ichm_ape_info()
            ichm_ape_get_info(decoder, &info)
            result.frames = info.total_frames
            guard info.bits_per_sample == 16, info.is_float == 0 else {
                result.failure = "unexpected format: \(info.bits_per_sample) bit"
                return result
            }
            if start > 0, ichm_ape_seek(decoder, start) != 0 {
                result.failure = "seek failed"
                return result
            }
            let channels = Int(info.channels)
            var buffer = [Int16](repeating: 0, count: 4096 * channels)
            while true {
                let got = Int(ichm_ape_read(decoder, &buffer, 4096))
                if got < 0 { result.failure = "read failed"; break }
                if got == 0 { break }
                for i in 0..<got {
                    for channel in 0..<2 { result.samples[channel].append(Float(buffer[i * channels + channel]) / 32768) }
                }
            }
            return result
        }

        // MARK: Tests

        @Test("WavPack and APE decode sample by sample, with exactly the length of the file", arguments: ["a.wv", "a.ape"])
        func exact(name: String) throws {
            let file = RampFile.a.stored(as: name)
            let url = try file.url()
            let d = name.hasSuffix(".wv") ? decodeWavPack(url) : decodeAPE(url)
            #expect(d.failure == nil, "\(d.failure ?? "")")
            #expect(d.frames == Int64(file.frames))
            #expect(d.samples.frameCount == file.frames)
            #expect(maxDeviation(d.samples, from: 0, count: file.frames) { file.value($0, channel: $1) } == 0)
        }

        @Test("WavPack and APE seek to the exact frame", arguments: ["a.wv", "a.ape"])
        func seek(name: String) throws {
            let file = RampFile.a.stored(as: name)
            let url = try file.url()
            for first in [1, 4097, 70_001, file.frames - 10] {
                let d = name.hasSuffix(".wv") ? decodeWavPack(url, from: Int64(first)) : decodeAPE(url, from: Int64(first))
                #expect(d.failure == nil, "\(first): \(d.failure ?? "")")
                #expect(d.samples.frameCount == file.frames - first, "\(first)")
                #expect(maxDeviation(d.samples, from: 0, count: d.samples.frameCount) { file.value(first + $0, channel: $1) } == 0,
                        "\(first)")
            }
        }

        @Test("a file that isn't WavPack or APE is refused, not a crash", arguments: ["broken/garbage.mp3", "formats/t.flac"])
        func refused(fixture: String) throws {
            let url = try Fixtures.url(fixture)
            #expect(decodeWavPack(url).failure != nil)
            #expect(decodeAPE(url).failure != nil)
        }
    }
}
