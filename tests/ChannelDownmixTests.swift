import AVFoundation
import AudioToolbox
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("ChannelDownmix")
    struct ChannelDownmixTests {
        private static let surround51: [AudioChannelLabel] = [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ]

        /// A format with `channels` channels. Anything beyond stereo needs a layout, `AVAudioFormat` is nil without.
        private func format(channels: Int) -> AVAudioFormat {
            if channels <= 2 {
                return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                     channels: AVAudioChannelCount(channels), interleaved: false)!
            }
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, interleaved: false, channelLayout: layout)
        }

        private func buffer(channels: Int, frames: Int = 64, _ values: [Float]) -> AVAudioPCMBuffer {
            let format = format(channels: channels)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            b.frameLength = AVAudioFrameCount(frames)
            for c in 0..<channels {
                for i in 0..<frames { b.floatChannelData![c][i] = values[c] }
            }
            return b
        }

        private func stereoBuffer(frames: Int = 64) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
            return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        }

        private func mix(_ downmix: ChannelDownmix, channels: Int, _ values: [Float]) -> (left: Float, right: Float) {
            let out = stereoBuffer()
            downmix.apply(buffer(channels: channels, values), to: out)
            return (out.floatChannelData![0][10], out.floatChannelData![1][10])
        }

        // MARK: Stereo and mono

        @Test("stereo is copied bit for bit")
        func stereoCopy() {
            let downmix = ChannelDownmix(channelCount: 2)
            #expect(downmix.isStereoCopy)

            let source = buffer(channels: 2, frames: 1000, [0, 0])
            for i in 0..<1000 {
                source.floatChannelData![0][i] = Float(i) / 1000 - 0.5
                source.floatChannelData![1][i] = -Float(i) / 777
            }
            let out = stereoBuffer(frames: 1000)
            downmix.apply(source, to: out)
            #expect(out.frameLength == 1000)
            for i in 0..<1000 {
                #expect(out.floatChannelData![0][i] == source.floatChannelData![0][i])
                #expect(out.floatChannelData![1][i] == source.floatChannelData![1][i])
            }
        }

        @Test("stereo with explicit labels is still a plain copy")
        func stereoLabels() {
            #expect(ChannelDownmix(channelCount: 2, labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right]).isStereoCopy)
        }

        @Test("mono goes to both sides at full level")
        func mono() {
            let downmix = ChannelDownmix(channelCount: 1)
            #expect(!downmix.isStereoCopy)
            let m = mix(downmix, channels: 1, [0.5])
            #expect(m.left == 0.5 && m.right == 0.5)
            let full = mix(downmix, channels: 1, [1])
            #expect(full.left == 1 && full.right == 1)
        }

        // MARK: Multichannel

        @Test("5.1: front channels stay on their side, centre and surrounds are mixed in at -3 dB, LFE is dropped")
        func surround() {
            let downmix = ChannelDownmix(channelCount: 6, labels: Self.surround51)
            func one(_ channel: Int) -> (left: Float, right: Float) {
                var v = [Float](repeating: 0, count: 6)
                v[channel] = 1
                return mix(downmix, channels: 6, v)
            }
            let gain = downmix.coefficients[0].left          // the normalisation
            #expect(gain > 0.4 && gain < 0.42)               // 1 / (1 + 2 * 0.7071)

            let l = one(0), r = one(1), c = one(2), lfe = one(3), ls = one(4), rs = one(5)
            #expect(l.left == gain && l.right == 0)
            #expect(r.left == 0 && r.right == gain)
            #expect(abs(c.left - gain * 0.70710678) < 1e-6 && c.left == c.right)
            #expect(lfe.left == 0 && lfe.right == 0)
            #expect(abs(ls.left - gain * 0.70710678) < 1e-6 && ls.right == 0)
            #expect(rs.left == 0 && abs(rs.right - gain * 0.70710678) < 1e-6)
        }

        @Test("5.1 at full scale on every channel can't clip")
        func surroundNoClipping() {
            let downmix = ChannelDownmix(channelCount: 6, labels: Self.surround51)
            let m = mix(downmix, channels: 6, [1, 1, 1, 1, 1, 1])
            #expect(m.left <= 1.000001 && m.left > 0.99)
            #expect(m.right <= 1.000001 && m.right > 0.99)
        }

        @Test("rear surround labels are treated like side surrounds")
        func rearSurround() {
            let labels: [AudioChannelLabel] = [
                kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
            ]
            let downmix = ChannelDownmix(channelCount: 6, labels: labels)
            #expect(downmix.coefficients[4].left > 0 && downmix.coefficients[4].right == 0)
            #expect(downmix.coefficients[5].left == 0 && downmix.coefficients[5].right > 0)
        }

        @Test("a layout with unknown labels alternates between the sides, normalised")
        func unknownLabels() {
            let downmix = ChannelDownmix(channelCount: 4, labels: [kAudioChannelLabel_Unknown, kAudioChannelLabel_Unknown,
                                                                  kAudioChannelLabel_Unknown, kAudioChannelLabel_Unknown])
            let m = mix(downmix, channels: 4, [1, 1, 1, 1])
            #expect(m.left > 0.99 && m.left <= 1.000001)
            #expect(m.right > 0.99 && m.right <= 1.000001)
            #expect(downmix.coefficients[0].right == 0 && downmix.coefficients[1].left == 0)
        }

        @Test("without labels (or with the wrong number of them) channels alternate")
        func noLabels() {
            for labels in [nil, [kAudioChannelLabel_Left]] as [[AudioChannelLabel]?] {
                let downmix = ChannelDownmix(channelCount: 3, labels: labels)
                #expect(downmix.coefficients.count == 3)
                let m = mix(downmix, channels: 3, [1, 1, 1])
                #expect(m.left > 0.99 && m.left <= 1.000001)
                #expect(m.right > 0.49 && m.right <= 1.000001)
            }
        }

        @Test("silence stays silent, signs are kept")
        func silenceAndSign() {
            let downmix = ChannelDownmix(channelCount: 6, labels: Self.surround51)
            let zero = mix(downmix, channels: 6, [0, 0, 0, 0, 0, 0])
            #expect(zero.left == 0 && zero.right == 0)
            let negative = mix(downmix, channels: 6, [-1, -1, -1, 0, -1, -1])
            #expect(negative.left < -0.99 && negative.right < -0.99)
        }

        @Test("an empty buffer produces an empty buffer")
        func empty() {
            let downmix = ChannelDownmix(channelCount: 6, labels: Self.surround51)
            let out = stereoBuffer()
            out.frameLength = 5
            downmix.apply(buffer(channels: 6, frames: 0, [0, 0, 0, 0, 0, 0]), to: out)
            #expect(out.frameLength == 0)
        }

        @Test("the destination is overwritten, not accumulated into")
        func overwrites() {
            let downmix = ChannelDownmix(channelCount: 6, labels: Self.surround51)
            let out = stereoBuffer()
            for _ in 0..<3 { downmix.apply(buffer(channels: 6, [1, 1, 1, 1, 1, 1]), to: out) }
            #expect(out.floatChannelData![0][5] <= 1.000001)
        }

        // MARK: Real layouts

        @Test("the layout of real files is read: stereo, mono and 5.1")
        func realLayouts() throws {
            let stereo = try AVAudioFile(forReading: RampFile.a.url())
            #expect(ChannelDownmix(format: stereo.processingFormat).isStereoCopy)

            let mono = try AVAudioFile(forReading: RampFile.mono22.url())
            #expect(ChannelDownmix(format: mono.processingFormat).coefficients == [.init(left: 1, right: 1)])

            let file = try AVAudioFile(forReading: RampFile.surround.url())
            let labels = ChannelDownmix.labels(of: file.processingFormat)
            #expect(labels?.count == 6)
            #expect(labels?[0] == kAudioChannelLabel_Left)
            #expect(labels?[2] == kAudioChannelLabel_Center)
            #expect(labels?[3] == kAudioChannelLabel_LFEScreen)
            let downmix = ChannelDownmix(format: file.processingFormat)
            #expect(downmix.coefficients[3] == .init(left: 0, right: 0))     // LFE
            #expect(downmix.coefficients[2].left > 0 && downmix.coefficients[2].right > 0)   // centre
        }
    }
}
