import Foundation

/// Owns the in-memory config and `config.json`.
///
/// - Read once at startup (a missing/broken file results in defaults being written).
/// - Written on every change. Writes are coalesced for a short moment so that continuous
///   changes (window drag, divider drag) don't hammer the disk; `flush()` forces a write.
@MainActor
final class ConfigStore {
    static let shared = ConfigStore(paths: .current)

    private(set) var config: AppConfig

    private let paths: AppPaths
    private let saveDelay: Duration
    private var saveTask: Task<Void, Never>?
    nonisolated static let defaultSaveDelay: Duration = .milliseconds(250)

    init(paths: AppPaths, saveDelay: Duration = ConfigStore.defaultSaveDelay) {
        self.paths = paths
        self.saveDelay = saveDelay
        config = AppConfig()
        load()
    }

    /// Applies `mutate` to the config and schedules a write if anything changed.
    func update(_ mutate: (inout AppConfig) -> Void) {
        var updated = config
        mutate(&updated)
        guard updated != config else { return }
        config = updated
        scheduleSave()
    }

    /// Writes any pending change right now.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    // MARK: - Loading

    private func load() {
        let url = paths.configURL
        do {
            try FileManager.default.createDirectory(at: paths.workDir, withIntermediateDirectories: true)
        } catch {
            Log.error("can't create \(paths.workDir.path): \(error.localizedDescription)")
        }

        let existing = try? Data(contentsOf: url)
        if let existing {
            do {
                let decoded = try JSONDecoder().decode(AppConfig.self, from: existing)
                config = decoded.validated()
                Log.info("config loaded from \(url.path)")
            } catch {
                Log.error("config.json is not valid (\(error.localizedDescription)), using defaults")
                config = AppConfig()
            }
        } else {
            Log.info("no config found, writing defaults to \(url.path)")
        }

        // Normalizes the file: creates it if missing, fills in missing keys, applies resets.
        if Self.encode(config) != existing {
            write()
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        let saveDelay = self.saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.write()
        }
    }

    private func write() {
        guard let data = Self.encode(config) else { return }
        do {
            try FileManager.default.createDirectory(at: paths.workDir, withIntermediateDirectories: true)
            try data.write(to: paths.configURL, options: .atomic)
        } catch {
            Log.error("can't write config: \(error.localizedDescription)")
        }
    }

    static func encode(_ config: AppConfig) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(config) else { return nil }
        data.append(0x0A)
        return data
    }
}
