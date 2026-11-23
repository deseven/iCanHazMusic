// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The sheet that adds or edits a Subsonic connection. Nothing is saved until Save; the connection can be tried first
/// with the values as they are in the sheet (every address on its own).
struct SubsonicConnectionSheet: View {
    let isNew: Bool
    /// The other connections, which the name has to differ from.
    let others: [SubsonicConnectionConfig]
    let onSave: (SubsonicConnectionConfig) -> Void

    @State private var draft: SubsonicConnectionConfig
    @State private var testing = false
    @State private var testResults: [SubsonicConnection.RouteTest]?
    @State private var testTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    init(connection: SubsonicConnectionConfig, isNew: Bool, others: [SubsonicConnectionConfig],
         onSave: @escaping (SubsonicConnectionConfig) -> Void) {
        self.isNew = isNew
        self.others = others
        self.onSave = onSave
        _draft = State(initialValue: connection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Subsonic Connection" : "Edit Subsonic Connection")
                .font(.headline)

            field("Name", hint: "Only for you to tell the connections apart; it can be changed any time.") {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Public endpoint", hint: publicHint) {
                TextField("https://", text: $draft.publicEndpoint)
                    .textFieldStyle(.roundedBorder)
            }

            field("Local endpoint", hint: localHint) {
                TextField("http://", text: $draft.localEndpoint)
                    .textFieldStyle(.roundedBorder)
            }

            field("Username", hint: nil) {
                TextField("", text: $draft.username)
                    .textFieldStyle(.roundedBorder)
            }

            field("Password", hint: "Kept in the config file obfuscated, not encrypted: the server needs the password "
                  + "itself to make the login token that every request carries.") {
                SecureField("", text: $draft.password)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Send scrobbles", isOn: $draft.sendScrobbles)
                    .toggleStyle(.switch)
                Text("Tell the server about the tracks you've listened to that came from it. It counts them as plays, "
                     + "and passes them on if it is set up for that (Last.fm, ListenBrainz).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cache size")
                    Spacer()
                    Text(draft.cacheSize.title)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: cacheSizePosition, in: 0...Double(Self.unlimitedPosition), step: 1)
                Text("How much of the downloaded songs is kept for the next time. None: a file is deleted as soon as "
                     + "nothing needs it, and the folder is emptied at launch. A size: when it is exceeded, the files "
                     + "played longest ago are deleted. Unlimited: nothing is ever deleted. Removing the connection "
                     + "deletes its files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Test Connection") { test() }
                        .disabled(testing || !canTest)
                    if testing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                if let testResults {
                    ForEach(testResults, id: \.route) { result in
                        resultLine(result)
                    }
                }
            }
            .font(.callout)

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
        .frame(width: Layout.subsonicSheetWidth)
        .onChange(of: draft) {
            // What a test said is about the values it was started with.
            testTask?.cancel()
            testing = false
            testResults = nil
        }
        .onDisappear { testTask?.cancel() }
    }

    // MARK: - Cache size

    /// The slider's positions: 0 is none, then 1 GB to 100 GB a GB at a time, then unlimited.
    private static let unlimitedPosition = ConfigLimits.subsonicCacheMaxGB + 1

    private var cacheSizePosition: Binding<Double> {
        Binding(
            get: {
                switch draft.cacheSize {
                case .off: 0
                case .limited(let gigabytes): Double(gigabytes)
                case .unlimited: Double(Self.unlimitedPosition)
                }
            },
            set: { value in
                let position = Int(value.rounded())
                let size: SubsonicCacheSize = switch position {
                case ..<1: .off
                case Self.unlimitedPosition...: .unlimited
                default: .limited(gigabytes: position)
                }
                if size != draft.cacheSize { draft.cacheSize = size }
            }
        )
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

    @ViewBuilder
    private func resultLine(_ result: SubsonicConnection.RouteTest) -> some View {
        switch result.outcome {
        case .success(let info):
            Label("\(result.route.title): \(info).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let error):
            Label("\(result.route.title): \(SubsonicService.sentence(error.message))", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var publicHint: String {
        var text = "The address that works from anywhere. At least one of the two endpoints is needed."
        text += insecureNote(draft.publicEndpoint)
        return text
    }

    private var localHint: String {
        var text = "The address that works only in your network. While it answers, it is used instead of the public "
            + "one (it is looked at once a minute)."
        text += insecureNote(draft.localEndpoint)
        return text
    }

    private func insecureNote(_ endpoint: String) -> String {
        guard endpoint.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") else { return "" }
        return "\nNot encrypted: what you listen to, and the login token of every request, can be read by anyone on the network."
    }

    private var problem: String? {
        draft.normalized.problem(among: others)
    }

    /// The connection can be tried with what is needed for it (no name required).
    private var canTest: Bool {
        !draft.routes.isEmpty && !draft.username.trimmingCharacters(in: .whitespaces).isEmpty && !draft.password.isEmpty
    }

    private func test() {
        let candidate = draft.normalized
        testing = true
        testResults = nil
        testTask = Task {
            let results = await SubsonicService.shared.test(candidate)
            guard !Task.isCancelled else { return }
            testResults = results
            testing = false
        }
    }
}
