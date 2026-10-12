// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Thin click/drag-to-seek progress bar (the "Default" seek bar style). While dragging it only previews
/// (`scrubbing`); the seek itself happens once, when the mouse is released.
///
/// The fill moves by a Core Animation run by the system from `anchor`, so playing costs no redraws or view updates
/// here (SwiftUI is only involved when the anchor changes).
struct SeekBar: View {
    let anchor: PositionAnchor
    let total: Double
    /// The position being dragged to, nil when not dragging.
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            SeekBarTrack(anchor: anchor, total: total, scrubbing: scrubbing)
                .frame(height: Layout.seekbarBarHeight)
                .frame(width: geo.size.width, height: geo.size.height)
                // The whole frame, including the margin above and below the drawn bar, takes the mouse.
                .seekGesture(width: geo.size.width, total: total, scrubbing: $scrubbing, onSeek: onSeek)
        }
        .frame(height: Layout.seekbarHeight)
    }
}

private struct SeekBarTrack: NSViewRepresentable {
    let anchor: PositionAnchor
    let total: Double
    let scrubbing: Double?

    func makeNSView(context: Context) -> SeekBarTrackView { SeekBarTrackView() }

    func updateNSView(_ view: SeekBarTrackView, context: Context) {
        let environment = context.environment
        view.update(anchor: anchor, total: total, scrubbing: scrubbing,
                    trackColor: Color.secondary.opacity(0.25).resolve(in: environment).cgColor,
                    fillColor: Color.accentColor.resolve(in: environment).cgColor)
    }
}

/// The bar: a rounded track clipping a plain fill whose width is animated linearly from where the position is now to
/// the end of the track. Playing needs no further work from the app.
private final class SeekBarTrackView: NSView {
    private let track = CALayer()
    private let fill = CALayer()

    private var anchor = PositionAnchor.stopped
    private var total = 0.0
    private var scrubbing: Double?
    /// The size the animation was made for.
    private var appliedSize = CGSize.zero
    private var applied = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        track.masksToBounds = true
        track.addSublayer(fill)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The mouse belongs to the SwiftUI gesture around this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(anchor: PositionAnchor, total: Double, scrubbing: Double?, trackColor: CGColor, fillColor: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.backgroundColor = trackColor
        fill.backgroundColor = fillColor
        CATransaction.commit()

        guard !applied || anchor != self.anchor || total != self.total || scrubbing != self.scrubbing else { return }
        self.anchor = anchor
        self.total = total
        self.scrubbing = scrubbing
        applyProgress()
    }

    override func layout() {
        super.layout()
        if bounds.size != appliedSize { applyProgress() }
    }

    /// Puts the fill where the position is now and, while it runs, lets it grow to the full width by the time the
    /// track ends.
    private func applyProgress() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        applied = true
        appliedSize = size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = size.height / 2
        fill.removeAllAnimations()
        fill.position = CGPoint(x: 0, y: size.height / 2)

        func width(of seconds: Double) -> CGFloat {
            total > 0 ? size.width * CGFloat(min(max(seconds / total, 0), 1)) : 0
        }
        func setFill(width: CGFloat) {
            fill.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        }

        if let scrubbing {
            setFill(width: width(of: scrubbing))
        } else {
            let now = anchor.position(at: ProcessInfo.processInfo.systemUptime)
            let start = width(of: now)
            if anchor.isRunning, total > 0, now < total {
                setFill(width: size.width)
                let animation = CABasicAnimation(keyPath: "bounds.size.width")
                animation.fromValue = start
                animation.toValue = size.width
                animation.duration = total - now
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                fill.add(animation, forKey: "progress")
            } else {
                setFill(width: start)
            }
        }
        CATransaction.commit()
    }
}
