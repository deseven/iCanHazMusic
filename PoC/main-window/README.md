# Main window PoC

```
[ sidebar (toggle) ] [ playlist ] [ divider ] [ playback block ]
```

```
./build.sh run      # build + run (macOS 15.4+, no dependencies)
```

| File | Purpose |
|---|---|
| [`App.swift`](App.swift) | `WindowGroup`, 800×600 min/default size |
| [`MainWindow.swift`](MainWindow.swift) | `NavigationSplitView` shell, `PlayerArea` (width arithmetic), `SplitDivider`, placeholders, `Layout` constants |
| [`PlaybackBlock.swift`](PlaybackBlock.swift) | Album art, info, seek bar, transport buttons, volume, fake `PlaybackState` |

## Approach

1. **Sidebar** – `NavigationSplitView` (2 columns: sidebar + detail). The toggle button in the
   title bar, sidebar animation, translucent material and Ctrl-⌘-S / View menu item come for free.
   Width is limited with `navigationSplitViewColumnWidth(min:ideal:max:)` (works on the sidebar column).
2. **Window size** – `.frame(minWidth: 800, minHeight: 600)` + `.defaultSize` + `.windowResizability(.contentMinSize)`.
3. **Playlist | divider | block** – a plain `HStack` inside a `GeometryReader` with a custom
   `SplitDivider` (`DragGesture` + `.pointerStyle(.columnResize)`), *not* `HSplitView`.
4. **Album art drives block width.** Art is `.aspectRatio(1, .fit)` inside the block, so
   `art = blockWidth - 2*padding`. The allowed block width range is computed in `PlayerArea.blockWidthRange`:
   - min = 250 + 2*padding
   - max = min( area width − playlist min width, (area height − measured controls height − gaps) + 2*padding )

   The second term makes the art grow with the width only until the block content stops fitting
   vertically; dragging further is clamped (no empty space). The height of the controls below the
   art is measured with `onGeometryChange` (all texts are `lineLimit(1)` so it is stable).
5. The user's dragged width is stored as a *preferred* width and clamped on every layout pass,
   so shrinking then growing the window restores it.

## Why not the alternatives

| Option | Verdict |
|---|---|
| `NavigationSplitView` 3 columns (sidebar / content / detail) | Third column can't be hidden separately, `navigationSplitViewColumnWidth` is ignored on the detail column, and its width can't be derived from the height. |
| `HSplitView` inside detail | Works, but can't set max width on a pane (drag produces empty space), no collapse, no way to react to height for the art size, no way to read/write the divider position. Custom divider is ~25 lines and gives full control. |
| `.inspector` | Nice for a collapsible right panel, but it is a system-styled panel (own material, own toggle) and its width is not derivable from content height. Could be revisited if the block should be hideable. |
| `NSSplitViewController` via representable | Most native (snapping, collapse, autosave), but bridging SwiftUI hierarchy is heavy. Fallback if the custom divider isn't enough. |

## Not done / to try

- Persist sidebar visibility and block width (`@SceneStorage` / `@AppStorage`).
- Double-click on divider to reset width.
- Real playlist view (see [`../playlist-view`](../playlist-view)).
- Vertical alignment of the block when the window is much wider than tall (currently top-aligned).
