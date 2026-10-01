# Playlist view PoC

Album-grouped playlist: album header (cover, artist, album, year) followed by its tracks
(number, title, duration, codec). Headers and tracks are individually selectable. Stays fast
with thousands of tracks (tested up to 3000 albums).

```
./build.sh run      # build + run (macOS 15.4+, no dependencies)
```

Files:

| File | Purpose |
|---|---|
| [`VirtualPlaylistView.swift`](VirtualPlaylistView.swift) | **The actual component**: windowed `ScrollView`, selection, keyboard, row views |
| [`Model.swift`](Model.swift) | `Album`/`Track`, flattened `Row`s, row offsets, fake data generator, placeholder covers |
| [`App.swift`](App.swift) | Demo window (album count picker, select all/clear, status bar) |

## How it works

1. **Flat row list.** `[header, track, track, header, track, ...]`. No nested lists/tables.
2. **Exact geometry.** Row heights are fixed per kind (header 68, track 20), so
   `Playlist.rowOffsets` gives the exact Y of every row and the exact document height.
3. **Windowing.** `ScrollView` → `VStack` containing a top spacer, only the rows within the
   viewport ± 600pt, and a bottom spacer. The visible row window is derived with
   `onScrollGeometryChange` (macOS 15) and binary search; state only changes when the
   window actually changes, not on every scroll frame.
4. **Custom selection** (`Set<Int>` of row ids): click, ⌘-click toggle, ⇧-click range,
   ↑/↓ (⇧ to extend) with auto-scroll to keep the cursor row visible via `ScrollPosition`.
   Headers and tracks are independent items; use `Playlist.expandedTrackRows(_:)` to
   resolve "header selected ⇒ all its tracks" at action time (play, drag, ...).

## Why not the alternatives

| Option | Result |
|---|---|
| SwiftUI `List` | Fast, but on macOS it is `SwiftUIOutlineListView` with automatic row heights: after clicking a track far from the top it scrolls to a random place, prints `Application performed a reentrant operation in its NSTableView delegate`, and the I-beam cursor gets stuck. Not fixable from our side. |
| `ScrollView` + `LazyVStack` | Estimates heights of unrealised rows; with mixed heights the scroll bar/offset drift. Windowing with known heights avoids this. |
| SwiftUI `Table` | Can't host a differently shaped album header row. |
| `NSTableView` via `NSViewRepresentable` | Would work (exact `heightOfRow`), but looked messy in a first attempt and isn't needed now. Still the fallback if 50k+ rows are ever required. |

## Notes for the real app

- Covers: `CoverCache` generates placeholders synchronously. In the real app load
  downsampled thumbnails (ImageIO `CGImageSourceCreateThumbnailAtIndex`) asynchronously and
  cache in `NSCache`.
- Row ids are indices (fine for an immutable playlist). For an editable playlist use stable
  ids and recompute `rowOffsets` incrementally.
- Not implemented yet: drag-select, drag & drop reordering, context menu, double-click to
  play, "now playing" highlight, variable row height (would need `rowOffsets` only – the
  windowing logic doesn't care).
