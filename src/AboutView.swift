import SwiftUI

struct AboutView: View {
    private let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? AppConstants.appName
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        ?? "?.?.?"
    private let licenseText = AboutView.loadLicenseText()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            infoPanel
                .frame(width: 200)

            Divider()

            ScrollView {
                Text(licenseText)
                    .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
        }
        .padding(20)
        .frame(width: 700, height: 520)
    }

    // MARK: - Left panel

    private var infoPanel: some View {
        VStack(spacing: 2) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Text(appName)
                .font(.system(size: 18, weight: .bold))

            Text(appVersion)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            section("created by") {
                LinkText("deseven", url: AppConstants.websiteURL)
            }

            section("icons by") {
                LinkText("boxicons", url: AppConstants.boxiconsURL)
            }

            HStack(spacing: 16) {
                IconLink(imageName: "bx-kofi", url: AppConstants.kofiURL)
                IconLink(imageName: "bx-github", url: AppConstants.githubRepoURL)
                IconLink(imageName: "bx-reddit", url: AppConstants.redditURL)
                IconLink(imageName: "bx-discord", url: AppConstants.discordURL)
            }
            .padding(.top, 19)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: NSFont.systemFontSize, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 14)
    }

    // MARK: - Helpers

    private static func loadLicenseText() -> String {
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "License text not available."
    }
}

// MARK: - Link controls

/// A text link that opens a URL in the default browser.
private struct LinkText: View {
    let title: String
    let url: URL

    init(_ title: String, url: URL) {
        self.title = title
        self.url = url
    }

    var body: some View {
        Link(destination: url) {
            Text(title)
                .font(.system(size: NSFont.systemFontSize, weight: .medium))
        }
        .help(url.absoluteString)
        .pointerStyle(.link)
    }
}

/// A template icon (loaded from the bundle's Resources) that opens a URL when clicked.
private struct IconLink: View {
    let imageName: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            if let image = Self.loadImage(named: imageName) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "link")
                    .frame(width: 24, height: 24)
            }
        }
        .help(url.absoluteString)
        .pointerStyle(.link)
    }

    private static func loadImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}
