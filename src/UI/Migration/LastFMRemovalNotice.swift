// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Tells the user, once, that the Last.fm integration is gone and what to do about it. Shown at launch when the
/// config (or the settings of the previous version, see `MigrationActions`) had a Last.fm login: the login is
/// already dropped by then, so the message doesn't come back at the next start.
///
/// "Set Up Now" asks for Preferences > Scrobbling to open with a Last.fm service filled in
/// (`ScrobblingSetupRequest`), "Set Up Later" leaves it to the user.
@MainActor
enum LastFMRemovalNotice {
    private static let width: CGFloat = 440

    /// Call at launch after `MigrationActions.askAtLaunch()`: the question about the previous version comes first, and
    /// can add a Last.fm login to what is announced here. A modal alert, like the migration's: no window exists yet.
    static func showIfNeeded() {
        guard let login = ConfigStore.shared.takeLegacyLastFMNotice() else { return }
        Log.info("Last.fm removal notice shown")

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Last.fm scrobbling has been removed"
        alert.accessoryView = textView(message(for: login))
        alert.addButton(withTitle: "Set Up Now")
        let later = alert.addButton(withTitle: "Set Up Later")
        later.keyEquivalent = "\u{1b}"

        if alert.runModal() == .alertFirstButtonReturn {
            Log.info("Last.fm removal notice: setting up now")
            ScrobblingSetupRequest.shared.request(LegacyLastFM.suggestedService(for: login))
        } else {
            Log.info("Last.fm removal notice: setting up later")
        }
    }

    private static func message(for login: LegacyLastFM.Login) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()

        func add(_ text: String, font: NSFont? = nil, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font ?? body, .foregroundColor: NSColor.labelColor]
            if let link { attributes[.link] = link }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        add("Scrobbling to Last.fm STOPS WORKING IMMEDIATELY", font: bold)
        add(" and will not come back on its own: this version of \(AppConstants.appName) has no Last.fm integration "
            + "any more. To keep scrobbling, take the action described at the end.\n\n")
        add("Why:\n", font: bold)
        add("• Last.fm introduced paid API keys starting the 1st of December 2026 (")
        add("announcement", link: LegacyLastFM.announcementURL)
        add(").\n"
            + "• As an independent, non-profit developer I have no intention of paying for access to their API.\n"
            + "• Even if I did, the API key would ship inside the app, where it can be easily extracted and "
            + "leaked, and there is no real way to protect it.\n"
            + "• Overall, this is a hostile action towards third-party apps and services, and I'm not going to "
            + "support it.\n\n")
        add("What to do:\n", font: bold)
        add("Set up scrobbling in Preferences > Scrobbling. You can use the legacy Audioscrobbler API (Last.fm "
            + "still supports it, so your Last.fm account keeps working this way) or ListenBrainz, a free and "
            + "open alternative.\n\n")
        add("Set Up Now", font: bold)
        add(" opens Preferences > Scrobbling with a Last.fm service already filled in: its name and endpoint"
            + (login.username.map { " and your username (\($0))" } ?? "")
            + ". You only have to enter your password (the same one you use to "
            + "log in to Last.fm) and save. ")
        add("Set Up Later", font: bold)
        add(" leaves it to you, the same can be done any time in Preferences.")
        return result
    }

    /// A read-only text with working links, as high as its text.
    private static func textView(_ text: NSAttributedString) -> NSView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.frame.size.height = ceil(layout.usedRect(for: container).height)
        }
        return view
    }
}
