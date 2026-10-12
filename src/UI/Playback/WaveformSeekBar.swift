// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// The visual seek bar styles (everything of `SeekbarStyle` but the default one): the track over time, drawn from the
/// data of `Waveform`, in the accent colour on a transparent background. What is not played yet is half-transparent;
/// the played part is drawn at full opacity, so it "lights up" as the track plays. The current position is a thicker line.
/// Click/drag seeks like the default bar (`seekGesture`).
///
/// - `waveformRMS`: mirrored, rounded bars of the loudness.
/// - `waveformPeakRMS`: the peaks as a faint layer, the RMS in front of it.
/// - `waveformTriBand`: three nested layers (all frequencies, mid + high, high) in increasing opacity of the one colour.
/// - `waveformStructure`: the RMS bars in the colour of the section of the track they belong to (sections that sound
///   alike share a colour), ticks at the top and bottom where the sections change.
/// - `spectrogram`: frequency (low at the bottom) over time, the intensity as opacity.
///
/// While the waveform isn't there (being made, or the track can't be analysed) the bars are a dimmed dotted line at
/// minimum height; the played bars and the line work as usual, so the bar is usable from the first frame.
///
/// Like the default bar, it moves by Core Animation run by the system from `anchor` (see `SeekBar`), so playing costs
/// nothing here. The bar is drawn twice into images (all played, all not played yet; `WaveformImages`) when the waveform,
/// size or appearance changes; the played one is shown left of the position and the other right of it, and the line is
/// the position.
struct WaveformSeekBar: View {
    let style: SeekbarStyle
    let anchor: PositionAnchor
    let total: Double
    /// The position being dragged to, nil when not dragging.
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void

    private let service = WaveformService.shared

    var body: some View {
        // Read here, not inside the GeometryReader, so the view is redrawn when the waveform arrives.
        let waveform = service.current
        GeometryReader { geo in
            WaveformTrack(style: style, waveform: waveform, anchor: anchor, total: total, scrubbing: scrubbing)
                .frame(width: geo.size.width, height: geo.size.height)
                .seekGesture(width: geo.size.width, total: total, scrubbing: $scrubbing, onSeek: onSeek)
        }
        .frame(height: Layout.waveformSeekbarHeight)
    }
}

private struct WaveformTrack: NSViewRepresentable {
    let style: SeekbarStyle
    let waveform: Waveform?
    let anchor: PositionAnchor
    let total: Double
    let scrubbing: Double?

    func makeNSView(context: Context) -> WaveformTrackView { WaveformTrackView() }

    func updateNSView(_ view: WaveformTrackView, context: Context) {
        let environment = context.environment
        view.update(style: style, waveform: waveform, anchor: anchor, total: total, scrubbing: scrubbing,
                    colorScheme: environment.colorScheme,
                    accent: Color.accentColor.resolve(in: environment),
                    primary: Color.primary.resolve(in: environment))
    }
}

/// The layers of the bar. The two images are each shown through a mask: the played one through a mask that grows from
/// the left, the other through one that shrinks towards the right edge, so no pixel is drawn twice (the images are
/// translucent). While playing, the masks and the line are animated linearly to the end of the track.
private final class WaveformTrackView: NSView {
    private let artLayer = CALayer()
    private let playedLayer = CALayer()
    private let unplayedLayer = CALayer()
    private let playedMask = CALayer()
    private let unplayedMask = CALayer()
    private let lineLayer = CALayer()

    private static let lineWidth: CGFloat = 2.5
    /// Where the bars start when the waveform arrives, as a share of the height, then they rise.
    private static let growFrom: CGFloat = 0.04
    private static let growDuration: CFTimeInterval = 0.3

    private var style = SeekbarStyle.standard
    private var waveform: Waveform?
    private var anchor = PositionAnchor.stopped
    private var total = 0.0
    private var scrubbing: Double?
    private var colorScheme = ColorScheme.light
    private var accent: Color.Resolved?
    private var primary: Color.Resolved?

    /// What the images in the layers were made for, and what they were made of.
    private var rendered: WaveformImages.Request?
    private var renderScheduled = false
    private let artwork = WaveformArtwork()

    private var appliedSize = CGSize.zero
    private var appliedState: (PositionAnchor, Double, Double?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(artLayer)
        layer?.addSublayer(lineLayer)
        artLayer.addSublayer(unplayedLayer)
        artLayer.addSublayer(playedLayer)
        for image in [playedLayer, unplayedLayer] {
            image.contentsGravity = .resize
            image.magnificationFilter = .linear
        }
        playedLayer.mask = playedMask
        unplayedLayer.mask = unplayedMask
        playedMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        unplayedMask.anchorPoint = CGPoint(x: 1, y: 0.5)
        playedMask.backgroundColor = NSColor.black.cgColor
        unplayedMask.backgroundColor = NSColor.black.cgColor
        lineLayer.cornerRadius = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The mouse belongs to the SwiftUI gesture around this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(style: SeekbarStyle, waveform: Waveform?, anchor: PositionAnchor, total: Double, scrubbing: Double?,
                colorScheme: ColorScheme, accent: Color.Resolved, primary: Color.Resolved) {
        self.style = style
        self.waveform = waveform
        self.colorScheme = colorScheme
        self.accent = accent
        self.primary = primary

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.backgroundColor = primary.cgColor
        CATransaction.commit()

        scheduleRender()
        if appliedState == nil || appliedState! != (anchor, total, scrubbing) {
            self.anchor = anchor
            self.total = total
            self.scrubbing = scrubbing
            applyProgress()
        }
    }

    override func layout() {
        super.layout()
        if bounds.size != appliedSize {
            applyProgress()
            scheduleRender()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleRender()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleRender()
    }

    // MARK: Images

    private var request: WaveformImages.Request? {
        guard let accent, let primary, bounds.width >= 1, bounds.height >= 1 else { return nil }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return WaveformImages.Request(style: style, waveform: waveform, size: bounds.size, scale: scale,
                                      colorScheme: colorScheme, accent: accent, primary: primary)
    }

    /// Drawing the images is done on the next turn, not in the middle of a SwiftUI update or an AppKit layout pass.
    private func scheduleRender() {
        guard !renderScheduled, request != rendered else { return }
        renderScheduled = true
        Task { @MainActor [weak self] in
            self?.renderScheduled = false
            self?.renderNow()
        }
    }

    private func renderNow() {
        guard let request, request != rendered,
              let images = WaveformImages.render(request, artwork: artwork) else { return }
        let arrived = rendered != nil && rendered?.waveform == nil && request.waveform != nil
        rendered = request

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, image) in [(playedLayer, images.played), (unplayedLayer, images.unplayed)] {
            layer.contents = image
            layer.contentsScale = request.scale
        }
        CATransaction.commit()

        if arrived { grow() }
    }

    /// The bars rise from the dotted line when the waveform arrives.
    private func grow() {
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = Self.growFrom
        animation.toValue = 1
        animation.duration = Self.growDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        artLayer.add(animation, forKey: "grow")
    }

    // MARK: Position

    /// Puts the masks and the line where the position is now and, while it runs, lets them move to the end of the track
    /// by the time it ends.
    private func applyProgress() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        appliedSize = size
        appliedState = (anchor, total, scrubbing)

        let width = size.width
        let height = size.height
        let half = Self.lineWidth / 2
        func fraction(of seconds: Double) -> CGFloat {
            total > 0 ? CGFloat(min(max(seconds / total, 0), 1)) : 0
        }
        // The line stays inside the frame at the ends so it isn't cut off.
        func lineX(_ fraction: CGFloat) -> CGFloat { min(max(width * fraction, half), width - half) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artLayer.frame = bounds
        for layer in [playedLayer, unplayedLayer] { layer.frame = artLayer.bounds }
        playedMask.removeAllAnimations()
        unplayedMask.removeAllAnimations()
        lineLayer.removeAllAnimations()
        playedMask.position = CGPoint(x: 0, y: height / 2)
        unplayedMask.position = CGPoint(x: width, y: height / 2)
        lineLayer.bounds = CGRect(x: 0, y: 0, width: Self.lineWidth, height: height)

        func set(fraction f: CGFloat) {
            playedMask.bounds = CGRect(x: 0, y: 0, width: width * f, height: height)
            unplayedMask.bounds = CGRect(x: 0, y: 0, width: width * (1 - f), height: height)
            lineLayer.position = CGPoint(x: lineX(f), y: height / 2)
        }

        if let scrubbing {
            set(fraction: fraction(of: scrubbing))
        } else {
            let now = anchor.position(at: ProcessInfo.processInfo.systemUptime)
            let start = fraction(of: now)
            if anchor.isRunning, total > 0, now < total {
                set(fraction: 1)
                let duration = total - now
                func animate(_ layer: CALayer, _ keyPath: String, from: CGFloat, to: CGFloat) {
                    let animation = CABasicAnimation(keyPath: keyPath)
                    animation.fromValue = from
                    animation.toValue = to
                    animation.duration = duration
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)
                    layer.add(animation, forKey: "progress")
                }
                animate(playedMask, "bounds.size.width", from: width * start, to: width)
                animate(unplayedMask, "bounds.size.width", from: width * (1 - start), to: 0)
                animate(lineLayer, "position.x", from: lineX(start), to: lineX(1))
            } else {
                set(fraction: start)
            }
        }
        CATransaction.commit()
    }
}
