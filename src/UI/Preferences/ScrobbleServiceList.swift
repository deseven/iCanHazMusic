// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The scrobbling services as a list (sorted by name) with the switch that turns one on or off, its name, its status
/// (when it last scrobbled, with an exclamation mark if the last try failed) and the button that edits it. + adds a
/// service in a sheet, - removes the selected one after a confirmation.
struct ScrobbleServiceList: View {
    private let service = ScrobblingService.shared
    private let setup = ScrobblingSetupRequest.shared

    @State private var selection: UUID?
    @State private var window: NSWindow?
    @State private var editing: EditedService?

    /// What the sheet edits: a service that exists, or a new one.
    private struct EditedService: Identifiable {
        let service: ScrobbleServiceConfig
        let isNew: Bool
        var id: UUID { service.id }
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(service.services) { item in
                            row(item)
                        }
                    }
                }
                .frame(height: Layout.scrobbleListHeight)
                .overlay {
                    if service.services.isEmpty {
                        Text("No services. Click + to add one.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .componentListBox()

            HStack(spacing: 4) {
                Button { editing = EditedService(service: newService(), isNew: true) } label: {
                    Image(systemName: "plus").frame(width: 20, height: 18)
                }
                .help("Add a service")
                Button { removeSelected() } label: {
                    Image(systemName: "minus").frame(width: 20, height: 18)
                }
                .disabled(selectedService == nil)
                .help("Remove the selected service")
                Spacer()
            }
        }
        .background(WindowAccessor { window = $0 })
        .onAppear { openRequestedSetup() }
        .onChange(of: setup.pending) { openRequestedSetup() }
        .sheet(item: $editing) { edited in
            ScrobbleServiceSheet(service: edited.service, isNew: edited.isNew, others: service.services) { saved in
                if edited.isNew { service.add(saved) } else { service.update(saved) }
                selection = saved.id
            }
        }
    }

    /// A new service somebody has filled in for the user (the Last.fm notice): the sheet opens with it.
    private func openRequestedSetup() {
        guard let requested = setup.take() else { return }
        editing = EditedService(service: requested, isNew: true)
    }

    private var selectedService: ScrobbleServiceConfig? {
        service.services.first { $0.id == selection }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Layout.scrobbleSwitchColumnWidth, height: 1)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Last scrobble / Status").frame(width: Layout.scrobbleStatusColumnWidth, alignment: .leading)
            Color.clear.frame(width: Layout.scrobbleEditColumnWidth, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: Layout.componentRowHeight)
        .background(Color.secondary.opacity(0.12))
    }

    private func row(_ item: ScrobbleServiceConfig) -> some View {
        let status = service.status(of: item.id)
        return HStack(spacing: 8) {
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

            StatusText(status: status, enabled: item.enabled)
                .frame(width: Layout.scrobbleStatusColumnWidth, alignment: .leading)

            Button { editing = EditedService(service: item, isNew: false) } label: {
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

    private func newService() -> ScrobbleServiceConfig {
        ScrobbleServiceConfig(name: "", type: .listenbrainz, endpoint: "")
    }

    private func removeSelected() {
        guard let item = selectedService else { return }
        Task {
            let confirmed = await Dialogs.confirm(
                title: "Remove \"\(item.name)\"?",
                message: "Playback will no longer be sent to it, and the tracks that are still waiting to be sent are lost.",
                confirmTitle: "Remove",
                destructive: true,
                on: window
            )
            guard confirmed else { return }
            ScrobblingService.shared.remove(item.id)
            if selection == item.id { selection = nil }
        }
    }
}

/// When the service last scrobbled (N/A if it didn't since the app started), with a green checkmark if the last try
/// (authentication or a call) went through, or a red exclamation mark if it failed (the reason is its tooltip).
private struct StatusText: View {
    let status: ScrobblingService.Status
    let enabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(status.lastScrobble?.formatted(date: .abbreviated, time: .shortened) ?? "N/A")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.secondary)
            if enabled, let error = status.error {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(ScrobblingService.sentence(error))
            } else if enabled, status.isOK {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("The last attempt to reach the service went through.")
            }
        }
        .font(.callout)
    }
}
