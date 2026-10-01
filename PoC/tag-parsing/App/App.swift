import SwiftUI
import UniformTypeIdentifiers

// Harness for TagReader: add folders / files on the left, parsed tracks appear on the right *as soon as*
// their tags arrive (completion order, not file order - that is what a concurrent reader gives you).

@main
struct TagParsingApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("Tag parsing PoC") {
            ContentView()
                .frame(minWidth: 960, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 720)
    }
}

// MARK: - Model

@MainActor @Observable
final class LibraryModel {
    struct Source: Identifiable {
        enum State { case queued, scanning, reading, done }
        let id = UUID()
        let url: URL
        var state: State = .queued
        var total = 0
        var done = 0
    }

    struct Row: Identifiable {
        let id: Int                 // arrival order
        let sourceID: UUID
        let result: TagReadResult

        func isFallback(_ field: String) -> Bool {
            switch result.status {
            case .complete: false
            case .partial(let f): f.contains(field)
            case .noTags, .failed: true
            }
        }
    }

    struct Stats {
        var complete = 0, partial = 0, noTags = 0, failed = 0
        mutating func add(_ s: TagReadStatus) {
            switch s {
            case .complete: complete += 1
            case .partial: partial += 1
            case .noTags: noTags += 1
            case .failed: failed += 1
            }
        }
    }

    // UI state
    private(set) var sources: [Source] = []
    private(set) var rows: [Row] = []
    private(set) var stats = Stats()
    private(set) var busy = false
    private(set) var readSeconds = 0.0
    private(set) var readFiles = 0

    // Reader settings (apply to sources added afterwards)
    var strategy: TagReader.Strategy = .auto
    var concurrency = TagReader.defaultConcurrency

    // Bookkeeping
    private var knownPaths = Set<String>()
    private var sourcePaths: [UUID: [String]] = [:]
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Void, Never>)?
    private var nextRowID = 0

    // MARK: Sources

    func add(_ urls: [URL]) {
        for url in urls where !sources.contains(where: { $0.url.path == url.path }) {
            let s = Source(url: url)
            sources.append(s)
            queue.append(s.id)
        }
        startWorker()
    }

    func removeSources(_ ids: Set<UUID>) {
        for id in ids {
            if current?.id == id { current?.task.cancel() }
            queue.removeAll { $0 == id }
            for p in sourcePaths[id] ?? [] { knownPaths.remove(p) }
            sourcePaths[id] = nil
        }
        sources.removeAll { ids.contains($0.id) }
        rows.removeAll { ids.contains($0.sourceID) }
        recomputeStats()
    }

    func removeRows(_ ids: Set<Int>) {
        for r in rows where ids.contains(r.id) { knownPaths.remove(r.result.url.path) }
        rows.removeAll { ids.contains($0.id) }
        recomputeStats()
    }

    func clear() { removeSources(Set(sources.map(\.id))) }

    private func recomputeStats() {
        var s = Stats()
        for r in rows { s.add(r.result.status) }
        stats = s
    }

    // MARK: Pipeline (sources are processed one after another; files inside a source concurrently)

    private func startWorker() {
        guard worker == nil else { return }
        busy = true
        worker = Task {
            while let id = queue.first {
                queue.removeFirst()
                let t = Task { await ingest(id) }
                current = (id, t)
                await t.value
                current = nil
            }
            busy = false
            worker = nil
        }
    }

    private func update(_ id: UUID, _ body: (inout Source) -> Void) {
        if let i = sources.firstIndex(where: { $0.id == id }) { body(&sources[i]) }
    }

    private func ingest(_ id: UUID) async {
        guard let url = sources.first(where: { $0.id == id })?.url else { return }

        update(id) { $0.state = .scanning }
        let files = await Task.detached(priority: .userInitiated) { AudioFileScanner.scan(urls: [url]) }.value
        guard !Task.isCancelled, sources.contains(where: { $0.id == id }) else { return }

        let fresh = files.filter { knownPaths.insert($0.path).inserted }   // skip files already in the list
        sourcePaths[id] = fresh.map(\.path)
        update(id) { $0.total = fresh.count; $0.state = .reading }

        let reader = TagReader(strategy: strategy, concurrency: concurrency)
        let clock = ContinuousClock()
        let t0 = clock.now
        var lastFlush = t0
        var batch: [Row] = []

        // Results are pushed to the UI in ~100 ms batches so thousands of quick files don't thrash SwiftUI.
        func flush() {
            guard !batch.isEmpty else { return }
            if sources.contains(where: { $0.id == id }) {
                rows.append(contentsOf: batch)
                for r in batch { stats.add(r.result.status) }
                update(id) { $0.done += batch.count }
            }
            batch.removeAll(keepingCapacity: true)
        }

        var n = 0
        for await result in reader.read(urls: fresh) {
            if Task.isCancelled { break }
            batch.append(Row(id: nextRowID, sourceID: id, result: result))
            nextRowID += 1
            n += 1
            if clock.now - lastFlush > .milliseconds(100) { flush(); lastFlush = clock.now }
        }
        flush()

        if !Task.isCancelled {
            let d = clock.now - t0
            readSeconds += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            readFiles += n
            update(id) { $0.state = .done }
        }
    }
}

// MARK: - Views

/// What the table can be filtered by. `empty set` == show everything.
enum StatusFilter: String, CaseIterable, Identifiable {
    case ok, partial, noTags, failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ok: "OK"
        case .partial: "Missing fields"
        case .noTags: "No tags"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .noTags: "questionmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ok: .green
        case .partial: .orange
        case .noTags: .secondary
        case .failed: .red
        }
    }

    static func of(_ status: TagReadStatus) -> StatusFilter {
        switch status {
        case .complete: .ok
        case .partial: .partial
        case .noTags: .noTags
        case .failed: .failed
        }
    }
}

struct ContentView: View {
    @State private var model = LibraryModel()
    @State private var showImporter = false
    @State private var selectedSources = Set<UUID>()
    @State private var selectedRows = Set<Int>()
    @State private var statusFilter = Set<StatusFilter>()

    /// Rows matching the current status filter (all rows when the filter is empty).
    private var visibleRows: [LibraryModel.Row] {
        statusFilter.isEmpty ? model.rows
            : model.rows.filter { statusFilter.contains(StatusFilter.of($0.result.status)) }
    }

    private func filterCount(_ f: StatusFilter) -> Int {
        switch f {
        case .ok: model.stats.complete
        case .partial: model.stats.partial
        case .noTags: model.stats.noTags
        case .failed: model.stats.failed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                sourceList
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                trackTable
                    .frame(minWidth: 600)
            }
            Divider()
            statusBar
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder, .item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in model.add(urls); return true }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Add folders / files…") { showImporter = true }
                .keyboardShortcut("o")
            Button("Remove selected") {
                model.removeSources(selectedSources); selectedSources = []
            }
            .disabled(selectedSources.isEmpty)
            Button("Clear all") { model.clear(); selectedSources = []; selectedRows = [] }
                .disabled(model.sources.isEmpty)

            Spacer()

            Picker("Strategy", selection: $model.strategy) {
                ForEach(TagReader.Strategy.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Picker("Parallel", selection: $model.concurrency) {
                ForEach(Set([1, 2, 4, 8, 16, 32, 64, TagReader.defaultConcurrency]).sorted(), id: \.self) { Text("\($0)").tag($0) }
            }
            .fixedSize()
        }
        .padding(8)
    }

    // MARK: sources

    private var sourceList: some View {
        List(model.sources, selection: $selectedSources) { s in
            HStack(spacing: 6) {
                Image(systemName: s.url.hasDirectoryPath ? "folder" : "music.note")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(s.url.deletingLastPathComponent().path)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
                switch s.state {
                case .queued: Text("queued").font(.caption).foregroundStyle(.secondary)
                case .scanning: ProgressView().controlSize(.small)
                case .reading: Text("\(s.done)/\(s.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .done: Text("\(s.done)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .onDeleteCommand {
            model.removeSources(selectedSources); selectedSources = []
        }
        .overlay {
            if model.sources.isEmpty {
                Text("Drop folders or audio files here\nor press ⌘O")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: tracks

    private var trackTable: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Text("Show:").font(.caption).foregroundStyle(.secondary)
            chip(.ok)
            chip(.partial)
            chip(.noTags)
            chip(.failed)
            if !statusFilter.isEmpty {
                Button {
                    statusFilter = []
                } label: {
                    Label("Clear filter", systemImage: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func chip(_ f: StatusFilter) -> some View {
        let on = statusFilter.contains(f)
        let count = filterCount(f)
        return Button {
            if on { statusFilter.remove(f) } else { statusFilter.insert(f) }
            selectedRows = selectedRows.intersection(visibleRows.map(\.id))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: f.symbol)
                Text("\(f.label) (\(count))")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? AnyShapeStyle(f.tint.opacity(0.22)) : AnyShapeStyle(.clear)))
            .overlay(Capsule().stroke(on ? AnyShapeStyle(f.tint) : AnyShapeStyle(.secondary.opacity(0.35))))
            .foregroundStyle(count == 0 && !on ? AnyShapeStyle(.tertiary) : AnyShapeStyle(f.tint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && !on)
    }

    private var table: some View {
        Table(visibleRows, selection: $selectedRows) {
            TableColumn("Artist") { r in cell(r.result.tags.artist, r.isFallback("artist")) }
            TableColumn("Title") { r in cell(r.result.tags.title, r.isFallback("title")) }
            TableColumn("Album") { r in cell(r.result.tags.album, r.isFallback("album")) }
            TableColumn("Year") { r in Text(r.result.tags.year ?? "") }.width(45)
            TableColumn("Trk") { r in Text(r.result.tags.trackNumber.map(String.init) ?? "") }.width(30)
            TableColumn("Time") { r in Text(Self.format(r.result.tags.duration)).monospacedDigit() }.width(45)
            TableColumn("Status") { r in statusCell(r.result.status) }.width(min: 90, ideal: 120)
            TableColumn("Artwork") { r in artworkCell(r.result.artwork) }.width(min: 90, ideal: 130)
            TableColumn("Via") { r in
                Text("\(r.result.sources.joined(separator: "+")) \(Int(r.result.elapsed * 1000)) ms")
                    .font(.caption).foregroundStyle(.secondary)
            }.width(min: 100, ideal: 170)
            TableColumn("File") { r in
                Text(r.result.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .help(r.result.url.path)
            }
        }
        .onDeleteCommand {
            model.removeRows(selectedRows); selectedRows = []
        }
        .overlay {
            if visibleRows.isEmpty, !model.rows.isEmpty {
                Text(statusFilter.isEmpty ? "" : "No tracks match the filter")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cell(_ text: String, _ fallback: Bool) -> some View {
        if fallback { Text(text).italic().foregroundStyle(.tertiary) } else { Text(text) }
    }

    @ViewBuilder
    private func statusCell(_ status: TagReadStatus) -> some View {
        switch status {
        case .complete:
            Label("ok", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial(let f):
            Label("no " + f.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .noTags:
            Label("no tags", systemImage: "questionmark.circle.fill").foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(.red).help(why).lineLimit(1)
        }
    }

    @ViewBuilder
    private func artworkCell(_ art: ArtworkSource) -> some View {
        switch art {
        case .cover(let name):
            Label(name, systemImage: "photo.fill").foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                .help("Folder image (priority 1)")
        case .embedded:
            Label("embedded", systemImage: "photo.on.rectangle").foregroundStyle(.blue)
                .help("Embedded in the audio file (priority 2)")
        case .anyImage(let name):
            Label(name, systemImage: "photo").foregroundStyle(.orange).lineLimit(1).truncationMode(.middle)
                .help("Any image in the folder (last resort, priority 3)")
        case .none:
            Text("none").foregroundStyle(.tertiary)
        }
    }

    static func format(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if model.busy { ProgressView().controlSize(.small) }
            Text("\(model.rows.count) tracks")
            Label("\(model.stats.complete)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("\(model.stats.partial)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Label("\(model.stats.noTags)", systemImage: "questionmark.circle.fill").foregroundStyle(.secondary)
            Label("\(model.stats.failed)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Spacer()
            if model.readSeconds > 0 {
                Text(String(format: "%d files in %.2f s = %.0f files/s (strategy %@, parallel %d)",
                            model.readFiles, model.readSeconds, Double(model.readFiles) / model.readSeconds,
                            model.strategy.rawValue, model.concurrency))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(6)
    }
}
