import Foundation
import Observation

/// Looks for a newer release of the app on GitHub and installs it (`UpdateInstaller`).
///
/// - Automatic checks (`isEnabled`, config `general.check_for_updates`, on by default) run once a day, the first
///   one a full day after `start()` (not at launch, to not bother someone who restarts the app often). An update that is found is handed to `onUpdateFound` (the UI asks the user),
///   unless the user skipped exactly that version (`skippedVersion`, config `general.skipped_update`).
/// - A manual check (`check(manual: true)`) works with `isEnabled` off too and ignores the skipped version.
/// - Only stable releases with an `ichm.zip` asset count; see `UpdateAPI`.
@MainActor
@Observable
final class UpdateService {
    static let shared = UpdateService(configStore: .shared, transport: URLSessionTransport(), currentVersion: AppConstants.appVersion)

    nonisolated static let defaultInitialDelay: Duration = .seconds(24 * 60 * 60)
    nonisolated static let defaultCheckInterval: Duration = .seconds(24 * 60 * 60)

    /// Check for updates automatically. Persisted in the config.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            configStore?.update { $0.general.checkForUpdates = isEnabled }
            Log.info("check for updates: \(isEnabled ? "on" : "off")")
            schedule()
        }
    }

    /// A check is in progress (manual or automatic).
    private(set) var isChecking = false

    /// Called when an automatic check found an update.
    @ObservationIgnored var onUpdateFound: ((UpdateInfo) -> Void)?

    @ObservationIgnored private let configStore: ConfigStore?
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let initialDelay: Duration
    @ObservationIgnored private let checkInterval: Duration
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    /// Where `skippedVersion` lives without a config store.
    @ObservationIgnored private var skipped: String?

    /// `configStore`: where `isEnabled` and `skippedVersion` are read from and kept; `nil` = on, and nothing is
    /// persisted.
    init(
        configStore: ConfigStore?,
        transport: HTTPTransport,
        currentVersion: String,
        initialDelay: Duration = UpdateService.defaultInitialDelay,
        checkInterval: Duration = UpdateService.defaultCheckInterval
    ) {
        self.configStore = configStore
        self.transport = transport
        self.currentVersion = currentVersion
        self.initialDelay = initialDelay
        self.checkInterval = checkInterval
        isEnabled = configStore?.config.general.checkForUpdates ?? true
    }

    /// The version the user skipped; only automatic checks respect it.
    var skippedVersion: String? {
        get {
            let value = configStore?.config.general.skippedUpdate ?? skipped
            return value?.isEmpty == false ? value : nil
        }
        set {
            skipped = newValue
            configStore?.update { $0.general.skippedUpdate = newValue ?? "" }
            if let newValue { Log.info("updates: skipping v\(newValue)") }
        }
    }

    /// Starts the automatic checks (if enabled). Called once at launch.
    func start() {
        started = true
        schedule()
    }

    // MARK: - Checking

    /// Asks GitHub for the newest release. Returns it if it is newer than the running app (and, for an automatic
    /// check, wasn't skipped), `nil` if there is nothing to offer. Throws if the check failed or one is running.
    func check(manual: Bool) async throws -> UpdateInfo? {
        guard !isChecking else { throw UpdateError.busy }
        isChecking = true
        defer { isChecking = false }
        Log.info("updates: checking (\(manual ? "manual" : "automatic"), current v\(currentVersion))")

        let answer = try await transport.perform(UpdateAPI.request())
        let releases = try UpdateAPI.releases(from: answer)
        guard let latest = UpdateAPI.latest(in: releases) else {
            Log.info("updates: no release found")
            return nil
        }
        guard SemVer(latest.version) > SemVer(currentVersion) else {
            Log.info("updates: up to date (latest v\(latest.version))")
            return nil
        }
        if !manual, skippedVersion == latest.version {
            Log.info("updates: v\(latest.version) is available, but was skipped")
            return nil
        }
        Log.info("updates: v\(latest.version) is available")
        return latest
    }

    /// Downloads and checks the release and starts the installer, which replaces the app after it has quit. The
    /// caller quits the app when this returns.
    func install(_ update: UpdateInfo) async throws {
        try await UpdateInstaller.install(update)
    }

    // MARK: - Automatic checks

    private func schedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard started, isEnabled else { return }
        let initialDelay = self.initialDelay
        let checkInterval = self.checkInterval
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                await self?.automaticCheck()
                try? await Task.sleep(for: checkInterval)
            }
        }
    }

    private func automaticCheck() async {
        do {
            guard let update = try await check(manual: false), isEnabled, !Task.isCancelled else { return }
            onUpdateFound?(update)
        } catch is CancellationError {
        } catch UpdateError.busy {
        } catch {
            Log.info("updates: check failed: \(error.localizedDescription)")
        }
    }
}
