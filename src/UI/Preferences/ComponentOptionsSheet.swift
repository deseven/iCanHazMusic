// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The sheet with the options of one now playing component, opened by the gear in `NowPlayingComponentList`.
/// Every option is written straight through to its owner, like everywhere in Preferences, so the sheet only has
/// to be closed. A component gets its options by a case in `options` (and `NowPlayingComponent.hasOptions`).
struct ComponentOptionsSheet: View {
    private static let textHint = "Click a variable to insert it where the cursor is. Brackets around a value that a "
        + "track doesn't have (the year, for example) are left out. To show a variable's name as it is, write "
        + "\\{artist} with a backslash."
    let component: NowPlayingComponent
    @Bindable var settings: NowPlayingSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(component.title) Options")
                .font(.headline)
            options
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: component == .seekbar || component == .controls ? 380 : 460)
    }

    @ViewBuilder
    private var options: some View {
        switch component {
        case .seekbar:
            OptionRow(
                title: "Style",
                description: "Default is a thin progress bar. The other styles aim to represent the track visually in "
                    + "several different ways, which requires pre-processing (once per track) and caching (on disk)."
            ) {
                Picker("", selection: $settings.style) {
                    ForEach(SeekbarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        case .controls:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Buttons")
                    Spacer()
                    Button("Reset Ordering & Visibility") { settings.resetControls() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(settings.controls == .default)
                }
                PlaybackControlList(settings: settings)
                Text("Drag to reorder. Click the eye to show or hide a button. The random buttons play a random "
                    + "track or the first track of a random album, whatever the playback order is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .title:
            TemplateOptions(title: "Text", description: Self.textHint, text: $settings.titleTemplate,
                            defaultText: AppConfig.NowPlaying.ComponentOptions.defaultTitle)
        case .subtitle:
            TemplateOptions(title: "Text", description: Self.textHint, text: $settings.subtitleTemplate,
                            defaultText: AppConfig.NowPlaying.ComponentOptions.defaultSubtitle)
        default:
            EmptyView()
        }
    }
}

/// The text of a component: a field, a row of buttons that insert the variables (`TemplateVariable`) into it, and the
/// link that brings the default back.
private struct TemplateOptions: View {
    let title: String
    let description: String
    @Binding var text: String
    let defaultText: String

    var body: some View {
        let field = Binding(
            get: { text },
            set: { text = String($0.prefix(ConfigLimits.componentTextMaxLength)) }
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Reset to Default") { text = defaultText }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(text == defaultText)
            }
            TextField("", text: field)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 4) {
                ForEach(TemplateVariable.allCases) { variable in
                    Button { insert(variable.token) } label: {
                        Text(variable.token).font(.caption.monospaced())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(variable.help)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// At the cursor (in place of the selection) when the field is being edited, else at the end. Going through the
    /// field's editor lets the text field report the change like any typing.
    private func insert(_ token: String) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
            editor.insertText(token, replacementRange: editor.selectedRange())
        } else {
            text = String((text + token).prefix(ConfigLimits.componentTextMaxLength))
        }
    }
}

/// One option: the title, the control and the description, like a row of the tabs.
private struct OptionRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            control()
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
