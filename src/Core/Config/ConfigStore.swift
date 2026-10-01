import Foundation

/// Owns the in-memory config and `config.json`.
///
/// - Read once at startup (a missing/broken file results in defaults being written).
/// - Written on every change. Writes are coalesced for a short moment so that continuous
///   changes (window drag, divider drag) don't hammer the disk; `flush()` forces a write.
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    private(set) var config: AppConfig

    private var saveTask: Task<Void, Never>?
    private static let saveDelay: Duration = .milliseconds(250)

    private init() {
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
        let url = AppPaths.configURL
        do {
            try FileManager.default.createDirectory(at: AppPaths.workDir, withIntermediateDirectories: true)
        } catch {
            Log.error("can't create \(AppPaths.workDir.path): \(error.localizedDescription)")
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
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.write()
        }
    }

    private func write() {
        guard let data = Self.encode(config) else { return }
        do {
            try FileManager.default.createDirectory(at: AppPaths.workDir, withIntermediateDirectories: true)
            try data.write(to: AppPaths.configURL, options: .atomic)
        } catch {
            Log.error("can't write config: \(error.localizedDescription)")
        }
    }

    private static func encode(_ config: AppConfig) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(config) else { return nil }
        data.append(0x0A)
        return data
    }
}
