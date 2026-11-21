// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import ImageIO

/// Puts album art on the general pasteboard as it was found: the file's/tag's own bytes under their own type
/// (JPEG stays JPEG, nothing is re-encoded).
///
/// Many apps (browsers in particular) only take PNG or TIFF from the pasteboard, so for any other format a TIFF of the
/// image is offered as well. It is made only if an app asks for it (`TIFFFallback`), since it is uncompressed
/// and big.
@MainActor
enum AlbumArtClipboard {
    /// Reads the original image again (from the file or tag it was found in, not kept in memory while shown) and
    /// puts it on the pasteboard. Whether that worked.
    static func copy(_ lookup: PlaybackArtwork.Lookup) async -> Bool {
        guard let found = await PlaybackArtwork.loadOriginal(lookup) else {
            Log.error("album art: can't copy, the original is gone or unreadable")
            return false
        }
        // A real copy: `found` may be a memory-mapped file, and the pasteboard may keep the data for a while.
        let original = found.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        return put(original)
    }

    private static func put(_ original: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil), CGImageSourceGetCount(source) > 0,
              let uti = CGImageSourceGetType(source) as String? else {
            Log.error("album art: can't copy, the bytes aren't a readable image")
            return false
        }

        let type = NSPasteboard.PasteboardType(uti)
        let item = NSPasteboardItem()
        item.setData(original, forType: type)
        if type != .png && type != .tiff {
            let fallback = TIFFFallback(original)
            self.fallback = fallback
            item.setDataProvider(fallback, forTypes: [.tiff])
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            Log.error("album art: can't copy to the pasteboard")
            return false
        }
        Log.info("album art: copied to the clipboard (\(uti), \(original.count) bytes)")
        return true
    }

    /// The pasteboard doesn't retain the provider of an item's data.
    private static var fallback: TIFFFallback?

    private final class TIFFFallback: NSObject, NSPasteboardItemDataProvider {
        private let original: Data

        init(_ original: Data) { self.original = original }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let image = NSImage(data: original), let tiff = image.tiffRepresentation else { return }
            item.setData(tiff, forType: .tiff)
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            Task { @MainActor in
                if AlbumArtClipboard.fallback === self { AlbumArtClipboard.fallback = nil }
            }
        }
    }
}
