// Quick probe of the three macOS tag APIs for a set of files:
//   swiftc -O -parse-as-library -o /tmp/api-probe api-probe.swift && /tmp/api-probe <file>...
// Prints, per file: AVURLAsset (playable/duration/mime + every metadata item), AudioToolbox info
// dictionary, and the Spotlight (MDItem) attributes. Use it to check which API sees which tags
// for a container that is not covered by the README table.
import Foundation
import AVFoundation
import AudioToolbox
import CoreServices

func avProbe(_ url: URL) async {
    let asset = AVURLAsset(url: url)
    do {
        let (formats, duration, playable) = try await asset.load(.availableMetadataFormats, .duration, .isPlayable)
        print("  [AV] playable=\(playable) duration=\(duration.seconds) formats=\(formats.map(\.rawValue))")
        for fmt in formats {
            for it in try await asset.loadMetadata(for: fmt) {
                let key = it.identifier?.rawValue ?? (it.key as? String) ?? "?"
                var val = "<nil>"
                if let s = try? await it.load(.stringValue) { val = s }
                else if let n = try? await it.load(.numberValue) { val = "num:\(n)" }
                else if let d = try? await it.load(.dataValue) { val = "data:\(d.count)B" }
                print("     \(key) = \(val.prefix(120))")
            }
        }
    } catch {
        print("  [AV] ERROR: \(error.localizedDescription)")
    }
}

func afProbe(_ url: URL) {
    var af: AudioFileID?
    let st = AudioFileOpenURL(url as CFURL, .readPermission, 0, &af)
    guard st == noErr, let af else { print("  [AF] open failed OSStatus=\(st)"); return }
    defer { AudioFileClose(af) }
    var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    var dict: Unmanaged<CFDictionary>?
    let s2 = AudioFileGetProperty(af, kAudioFilePropertyInfoDictionary, &size, &dict)
    if s2 == noErr, let d = dict?.takeRetainedValue() as? [String: Any] { print("  [AF] info=\(d)") }
    else { print("  [AF] info dict failed OSStatus=\(s2)") }
}

func mdProbe(_ url: URL) {
    guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return }
    print("  [MD] title=\(String(describing: MDItemCopyAttribute(item, kMDItemTitle))) "
          + "authors=\(String(describing: MDItemCopyAttribute(item, kMDItemAuthors))) "
          + "album=\(String(describing: MDItemCopyAttribute(item, kMDItemAlbum)))")
}

@main struct Probe {
    static func main() async {
        for p in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: p)
            print("== \(url.lastPathComponent)")
            await avProbe(url)
            afProbe(url)
            mdProbe(url)
        }
    }
}
