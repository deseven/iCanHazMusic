// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

extension View {
    /// Caps the width of the `NavigationSplitView` sidebar this view is placed in.
    ///
    /// On macOS SwiftUI doesn't pass the `max` of `navigationSplitViewColumnWidth` on to the
    /// underlying `NSSplitViewItem` (its `maximumThickness` stays unlimited), so the sidebar
    /// can be dragged arbitrarily wide. This sets the limit on the split view item directly,
    /// and keeps it there: SwiftUI resets it (e.g. when the sidebar is hidden and shown again).
    func sidebarMaxWidth(_ width: CGFloat) -> some View {
        background(SidebarWidthLimit(maxWidth: width))
    }
}

private struct SidebarWidthLimit: NSViewRepresentable {
    let maxWidth: CGFloat

    func makeNSView(context: Context) -> LimitView {
        let view = LimitView()
        view.maxWidth = maxWidth
        return view
    }

    func updateNSView(_ nsView: LimitView, context: Context) {
        nsView.maxWidth = maxWidth
        nsView.apply()
    }

    final class LimitView: NSView {
        var maxWidth: CGFloat = 0

        private weak var observedItem: NSSplitViewItem?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The split view controller may not be fully wired up yet at this point.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard window != nil, let item = sidebarItem() else { return }
            if item.maximumThickness != maxWidth { item.maximumThickness = maxWidth }
            observe(item)
        }

        /// Restores the limit whenever SwiftUI overwrites it.
        private func observe(_ item: NSSplitViewItem) {
            guard observedItem !== item else { return }
            observedItem = item
            observation = item.observe(\.maximumThickness, options: [.new]) { [weak self] item, _ in
                guard let self, item.maximumThickness != self.maxWidth else { return }
                item.maximumThickness = self.maxWidth
            }
        }

        /// The split view item whose view contains this view.
        private func sidebarItem() -> NSSplitViewItem? {
            var ancestor: NSView? = self
            while let view = ancestor {
                if let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController {
                    return controller.splitViewItems.first { item in
                        var v: NSView? = self
                        while let current = v {
                            if current === item.viewController.view { return true }
                            v = current.superview
                        }
                        return false
                    }
                }
                ancestor = view.superview
            }
            return nil
        }
    }
}
