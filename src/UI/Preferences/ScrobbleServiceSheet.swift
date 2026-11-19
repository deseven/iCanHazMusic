// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The sheet that adds or edits a scrobbling service. Nothing is saved until Save; the connection can be tried first
/// with the values as they are in the sheet.
struct ScrobbleServiceSheet: View {
    let isNew: Bool
    /// The other services, which the name has to differ from.
    let others: [ScrobbleServiceConfig]
    let onSave: (ScrobbleServiceConfig) -> Void

    @State private var draft: ScrobbleServiceConfig
    @State private var testing = false
    @State private var testResult: ScrobblingService.TestResult?
    @State private var testTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    init(service: ScrobbleServiceConfig, isNew: Bool, others: [ScrobbleServiceConfig],
         onSave: @escaping (ScrobbleServiceConfig) -> Void) {
        self.isNew = isNew
        self.others = others
        self.onSave = onSave
        _draft = State(initialValue: service)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Scrobbling Service" : "Edit Scrobbling Service")
                .font(.headline)

            field("Name", hint: "Only for you to tell the services apart.") {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Type", hint: nil) {
                Picker("", selection: typeBinding) {
                    ForEach(ScrobbleServiceConfig.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            field("Endpoint", hint: endpointHint) {
                HStack(spacing: 4) {
                    TextField("https://", text: $draft.endpoint)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(draft.type.commonEndpoints, id: \.url) { common in
                            Button("\(common.name) (\(common.url))") { draft.endpoint = common.url }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Common endpoints")
                }
            }

            if draft.type.usesUsername {
                field("Username", hint: "Optional. Some servers don't need it.") {
                    TextField("", text: $draft.username)
                        .textFieldStyle(.roundedBorder)
                }
            }

            field(draft.type.secretTitle, hint: secretHint) {
                SecureField("", text: $draft.secret)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Submit now playing", isOn: $draft.submitNowPlaying)
                .toggleStyle(.switch)

            HStack(spacing: 8) {
                Button("Test Connection") { test() }
                    .disabled(testing || !canTest)
                if testing {
                    ProgressView().controlSize(.small)
                }
                switch testResult {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft.normalized)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: Layout.scrobbleSheetWidth)
        .onChange(of: draft) {
            // What a test said is about the values it was started with.
            testTask?.cancel()
            testing = false
            testResult = nil
        }
        .onDisappear { testTask?.cancel() }
    }

    // MARK: - Pieces

    private func field<Content: View>(_ title: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            content()
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Changing the type clears an endpoint that was only picked from the common ones of the old type.
    private var typeBinding: Binding<ScrobbleServiceConfig.Kind> {
        Binding(
            get: { draft.type },
            set: { kind in
                guard kind != draft.type else { return }
                let normalized = ScrobbleServiceConfig.normalizedEndpoint(draft.endpoint)
                if draft.type.commonEndpoints.contains(where: { $0.url == normalized }) { draft.endpoint = "" }
                draft.type = kind
            }
        )
    }

    private var endpointHint: String {
        var text = "The address of the server, http or https, with or without a trailing slash. Pick a common one "
            + "from the menu or enter your own."
        if draft.endpoint.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") {
            text += draft.type == .listenbrainz
                ? "\nNot encrypted: the token is sent as it is, anyone on the network can read it."
                : "\nNot encrypted: what you listen to can be read by anyone on the network."
        }
        return text
    }

    private var secretHint: String {
        switch draft.type {
        case .audioscrobbler:
            "The password, token or key of the account, whatever the service calls it. It is never sent as it "
                + "is, only a hash made of it and the time. It is kept in the config file obfuscated, not encrypted."
        case .listenbrainz:
            "The token (or key) that lets listens be submitted for your account, usually found in the settings "
                + "of the service. It is kept in the config file obfuscated, not encrypted."
        }
    }

    private var problem: String? {
        draft.normalized.problem(among: others)
    }

    /// The connection can be tried with what is needed for it (no name required).
    private var canTest: Bool {
        ScrobbleServiceConfig.normalizedEndpoint(draft.endpoint) != nil && !draft.secret.isEmpty
    }

    private func test() {
        let candidate = draft.normalized
        testing = true
        testResult = nil
        testTask = Task {
            let result = await ScrobblingService.shared.test(candidate)
            guard !Task.isCancelled else { return }
            testResult = result
            testing = false
        }
    }
}
