import AVFoundation
import Foundation

// Minimal AVQueuePlayer gapless test.
//
// Plays the MP3 files in a directory (default: ./gapless-test) in alphabetical
// order, printing each filename as it becomes the current item, then exits when
// the queue finishes.
//
//   swift gapless-test/main.swift
//   swift gapless-test/main.swift "/Users/me/Music/Album"

let fm = FileManager.default
let cwd = fm.currentDirectoryPath

let argument = CommandLine.arguments.dropFirst().first ?? "gapless-test"
let directory = argument.hasPrefix("/") ? argument : cwd + "/" + argument

let files = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
    .filter { $0.lowercased().hasSuffix(".mp3") }
    .sorted()
    .map { directory + "/" + $0 }

guard !files.isEmpty else {
    print("No mp3 files in \(directory)")
    exit(1)
}

let items = files.map { AVPlayerItem(url: URL(fileURLWithPath: $0)) }
let player = AVQueuePlayer(items: items)

// Log each track as it becomes current.
let currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { player, _ in
    guard let asset = player.currentItem?.asset as? AVURLAsset else { return }
    print(asset.url.lastPathComponent)
    fflush(stdout)
}

// Fail loudly instead of silently playing nothing.
var itemObservations: [NSKeyValueObservation] = []
for item in items {
    itemObservations.append(item.observe(\.status, options: [.new]) { item, _ in
        if item.status == .failed {
            let name = (item.asset as? AVURLAsset)?.url.lastPathComponent ?? "?"
            print("Failed: \(name) - \(item.error?.localizedDescription ?? "unknown error")")
            exit(1)
        }
    })
}

// Exit once the last item finishes.
let endObserver = NotificationCenter.default.addObserver(
    forName: .AVPlayerItemDidPlayToEndTime,
    object: items[items.count - 1],
    queue: .main
) { _ in
    print("Done.")
    exit(0)
}

player.play()
RunLoop.main.run()

_ = currentItemObservation
_ = endObserver
_ = itemObservations
