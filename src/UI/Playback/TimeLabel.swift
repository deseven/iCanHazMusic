// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Observation
import SwiftUI

/// The `3:05 / 4:10` line: one centered line in the body font with fixed-width digits.
///
/// It follows the playback state by itself, so SwiftUI is not involved in the once-a-second changes: a SwiftUI view
/// reading `position` has its part of the view graph invalidated and the layout of the window re-run every time (that
/// was most of what the label cost). The text is a bare `CATextLayer`, not a text field: changing it doesn't set off
/// AppKit's display and layout cycle either. Its height is fixed (calculated once), so a new string doesn't invalidate
/// any layout.
struct TimeLabel: NSViewRepresentable {
    let state: PlaybackState
    /// The position being dragged to on the seek bar, nil when not dragging.
    let scrubbing: Double?

    /// The height of one line of the font, which is all the label ever shows.
    static let height: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: TimeLabelView.font))

    func makeNSView(context: Context) -> TimeLabelView { TimeLabelView(state: state) }

    func updateNSView(_ view: TimeLabelView, context: Context) {
        view.scrubbing = scrubbing
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimeLabelView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: Self.height)
    }
}

final class TimeLabelView: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private let state: PlaybackState
    private let textLayer = CATextLayer()
    private var shown = ""

    var scrubbing: Double? {
        didSet { if scrubbing != oldValue { refresh() } }
    }

    init(state: PlaybackState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        textLayer.font = Self.font
        textLayer.fontSize = Self.font.pointSize
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        layer?.addSublayer(textLayer)
        updateColor()
        updateScale()
        refresh()
        observe()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The mouse belongs to the SwiftUI views around this one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutAnimation { textLayer.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.labelColor.cgColor
            withoutAnimation { textLayer.foregroundColor = color }
        }
    }

    private func updateScale() {
        withoutAnimation { textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    /// Shows what the state says now, and again whenever its position or duration changes.
    private func observe() {
        withObservationTracking {
            _ = state.position
            _ = state.duration
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        let text = "\(Self.format(scrubbing ?? state.position)) / \(Self.format(state.duration))"
        guard text != shown else { return }
        shown = text
        withoutAnimation { textLayer.string = text }
    }

    private static func format(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
