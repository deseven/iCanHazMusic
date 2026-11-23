// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The Subsonic connections as a list (sorted by name) with the switch that turns one on or off, its name, its status
/// (when the server was last dealt with, with a checkmark or an exclamation mark for how that went) and the button that
/// edits it. + adds a connection in a sheet, - removes the selected one after a confirmation.
struct SubsonicConnectionList: View {
    private let service = SubsonicService.shared

    @State private var selection: UUID?
    @State private var window: NSWindow?
    @State private var editing: EditedConnection?

    /// What the sheet edits: a connection that exists, or a new one.
    private struct EditedConnection: Identifiable {
        let connection: SubsonicConnectionConfig
        let isNew: Bool
        var id: UUID { connection.id }
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(service.connections) { item in
                            row(item)
                        }
                    }
                }
                .frame(height: Layout.scrobbleListHeight)
                .overlay {
                    if service.connections.isEmpty {
                        Text("No connections. Click + to add one.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .componentListBox()

            HStack(spacing: 4) {
                Button { editing = EditedConnection(connection: SubsonicConnectionConfig(), isNew: true) } label: {
                    Image(systemName: "plus").frame(width: 20, height: 18)
                }
                .help("Add a connection")
                Button { removeSelected() } label: {
                    Image(systemName: "minus").frame(width: 20, height: 18)
                }
                .disabled(selectedConnection == nil)
                .help("Remove the selected connection")
                Spacer()
            }
        }
        .background(WindowAccessor { window = $0 })
        .sheet(item: $editing) { edited in
            SubsonicConnectionSheet(connection: edited.connection, isNew: edited.isNew, others: service.connections) { saved in
                if edited.isNew { service.add(saved) } else { service.update(saved) }
                selection = saved.id
            }
        }
    }

    private var selectedConnection: SubsonicConnectionConfig? {
        service.connections.first { $0.id == selection }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Layout.scrobbleSwitchColumnWidth, height: 1)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Last used / Status").frame(width: Layout.scrobbleStatusColumnWidth, alignment: .leading)
            Color.clear.frame(width: Layout.scrobbleEditColumnWidth, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: Layout.componentRowHeight)
        .background(Color.secondary.opacity(0.12))
    }

    private func row(_ item: SubsonicConnectionConfig) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { item.enabled }, set: { service.setEnabled($0, for: item.id) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: Layout.scrobbleSwitchColumnWidth, alignment: .leading)
                .help(item.enabled ? "Turn off" : "Turn on")

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.enabled ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            StatusText(status: service.status(of: item.id), enabled: item.enabled)
                .frame(width: Layout.scrobbleStatusColumnWidth, alignment: .leading)

            Button { editing = EditedConnection(connection: item, isNew: false) } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.secondary)
                    .frame(width: Layout.scrobbleEditColumnWidth, height: Layout.scrobbleRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Edit")
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.scrobbleRowHeight)
        .background(selection == item.id ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = item.id }
    }

    private func removeSelected() {
        guard let item = selectedConnection else { return }
        Task {
            let confirmed = await Dialogs.confirm(
                title: "Remove \"\(item.name)\"?",
                message: "The tracks that came from it stay in your playlists, but can't be played any more. "
                                    + "Its downloaded files are deleted.",
                confirmTitle: "Remove",
                destructive: true,
                on: window
            )
            guard confirmed else { return }
            SubsonicService.shared.remove(item.id)
            if selection == item.id { selection = nil }
        }
    }
}

/// When the server was last dealt with (N/A if it wasn't since the app started), with a green checkmark if that went
/// through, or a red exclamation mark if it failed (the reason is its tooltip).
private struct StatusText: View {
    let status: SubsonicService.Status
    let enabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(status.lastInteraction?.formatted(date: .abbreviated, time: .shortened) ?? "N/A")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.secondary)
            if enabled, let error = status.error {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(SubsonicService.sentence(error))
            } else if enabled, status.isOK {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(okHelp)
            }
        }
        .font(.callout)
    }

    private var okHelp: String {
        guard let route = status.route else { return "The last attempt to reach the server went through." }
        return "The last attempt to reach the server went through (\(route.title.lowercased()) address)."
    }
}
