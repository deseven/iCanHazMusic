import Foundation

// Benchmark / inspection CLI for TagReader.
//
//   bench dump [--strategy hybrid] <file-or-folder>...
//   bench run  --list /tmp/mus-files.txt --root /Users/deseven/shares/mus
//              [--files 100] [--rounds 3] [--strategies audioFile,avFoundation,hybrid,ffprobe]
//              [--conc 1,2,4,8,16] [--ext mp3,flac] [--seed 1]
//
// Fairness: every (round, config) run gets its OWN disjoint random set of album folders, so no run benefits
// from SMB / NAS caches warmed by a previous run. The config order is shuffled each round to spread NAS noise.

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct Config: Hashable {
    let strategy: String   // audioFile | avFoundation | hybrid | ffprobe
    let concurrency: Int
    var name: String { "\(strategy)/c\(concurrency)" }
}

struct RunStats {
    var seconds = 0.0
    var files = 0
    var bytes: Int64 = 0
    var complete = 0, partial = 0, noTags = 0, failed = 0
    var filesPerSec: Double { Double(files) / seconds }
    var mbPerSec: Double { Double(bytes) / 1e6 / seconds }
}

@main
struct Bench {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { usage() }
        args.removeFirst()
        switch cmd {
        case "dump": await dump(args)
        case "run": await run(args)
        case "scan": await scan(args)
        default: usage()
        }
    }

    /// Parses `--flag value` pairs (flags with no value are ignored).
    static func options(_ args: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i + 1 < args.count, args[i].hasPrefix("--") { out[args[i]] = args[i + 1]; i += 2 }
        return out
    }

    /// The indexed file list (`--list`, paths relative to `--root`), filtered by supported/`--ext`.
    static func loadFiles(list: String, root: String, exts: Set<String>) -> [URL] {
        guard let text = try? String(contentsOfFile: list, encoding: .utf8) else {
            print("cannot read \(list)"); exit(1)
        }
        var out: [URL] = []
        for line in text.split(separator: "\n") {
            let rel = String(line.hasPrefix("./") ? line.dropFirst(2) : Substring(line))
            let url = URL(fileURLWithPath: root + "/" + rel)
            let ext = url.pathExtension.lowercased()
            guard AudioFileScanner.supportedExtensions.contains(ext), exts.isEmpty || exts.contains(ext) else { continue }
            out.append(url)
        }
        return out
    }

    static func usage() -> Never {
        print("""
        usage:
          bench dump [--strategy audioFile|avFoundation|hybrid|auto] [--conc N] <file-or-folder>...
          bench run  --list FILE --root DIR [--files 100] [--rounds 3] [--strategies a,b,c (+ffprobe)]
                     [--conc 1,2,4,8] [--ext mp3,flac] [--seed 1] [--skip-sets N]
          bench scan --list FILE --root DIR [--strategies auto] [--conc 16] [--ext mp3,flac]
                     [--limit N] [--problems OUT.tsv]
                     Reads every listed file (no sampling) and reports status totals per strategy;
                     --problems writes one TSV line per non-complete file (status, detail, path).
        """)
        exit(2)
    }

    // MARK: dump

    static func dump(_ args: [String]) async {
        var strategy = TagReader.Strategy.auto
        var conc = 16
        var paths: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--strategy": i += 1; strategy = TagReader.Strategy(rawValue: args[i]) ?? .auto
            case "--conc": i += 1; conc = Int(args[i]) ?? 16
            default: paths.append(args[i])
            }
            i += 1
        }
        let files = AudioFileScanner.scan(urls: paths.map { URL(fileURLWithPath: $0) })
        let reader = TagReader(strategy: strategy, concurrency: conc)
        var results: [TagReadResult] = []
        for await r in reader.read(urls: files) { results.append(r) }
        for r in results.sorted(by: { $0.id < $1.id }) {
            let t = r.tags
            let dur = t.duration.map { String(format: "%.1fs", $0) } ?? "-"
            print("\(r.url.lastPathComponent)")
            print("   \(t.artist) | \(t.title) | \(t.album) | year=\(t.year ?? "-") track=\(t.trackNumber.map(String.init) ?? "-") dur=\(dur)")
            print("   status=\(r.status) via=\(r.sources.joined(separator: "+")) \(String(format: "%.1f", r.elapsed * 1000)) ms")
        }
    }

    // MARK: run

    static func run(_ args: [String]) async {
        let opts = options(args)
        guard let list = opts["--list"], let root = opts["--root"] else { usage() }

        let perSet = Int(opts["--files"] ?? "") ?? 100
        let rounds = Int(opts["--rounds"] ?? "") ?? 3
        let strategies = (opts["--strategies"] ?? "audioFile,avFoundation,hybrid").split(separator: ",").map(String.init)
        let concs = (opts["--conc"] ?? "1,2,4,8,16").split(separator: ",").compactMap { Int($0) }
        let exts = Set((opts["--ext"] ?? "").split(separator: ",").map { $0.lowercased() })
        let seed = UInt64(opts["--seed"] ?? "") ?? 1
        // With the same --seed/--files, skipping N sets guarantees these runs touch folders that
        // earlier runs did not (so no SMB / NAS cache carry-over).
        let skip = Int(opts["--skip-sets"] ?? "") ?? 0

        let configs = strategies.flatMap { s in concs.map { Config(strategy: s, concurrency: $0) } }
        let setsNeeded = rounds * configs.count

        // --- build disjoint sets of album folders
        guard let text = try? String(contentsOfFile: list, encoding: .utf8) else { print("cannot read \(list)"); exit(1) }
        var byDir: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let rel = String(line.hasPrefix("./") ? line.dropFirst(2) : Substring(line))
            let url = URL(fileURLWithPath: root + "/" + rel)
            let ext = url.pathExtension.lowercased()
            guard AudioFileScanner.supportedExtensions.contains(ext), exts.isEmpty || exts.contains(ext) else { continue }
            byDir[url.deletingLastPathComponent().path, default: []].append(url.path)
        }
        var rng = SplitMix64(state: seed)
        var dirs = byDir.keys.sorted()
        dirs.shuffle(using: &rng)

        var sets: [[URL]] = []
        var cursor = 0
        for _ in 0..<(skip + setsNeeded) {
            var set: [URL] = []
            while set.count < perSet, cursor < dirs.count {
                let files = byDir[dirs[cursor]]!.sorted()
                cursor += 1
                set += files.prefix(perSet - set.count).map { URL(fileURLWithPath: $0) }
            }
            sets.append(set)
        }
        guard sets.last.map({ $0.count == perSet }) == true else {
            print("not enough audio files for \(skip + setsNeeded) sets of \(perSet)"); exit(1)
        }
        sets.removeFirst(skip)

        print("collection: \(byDir.count) folders, \(byDir.values.reduce(0) { $0 + $1.count }) files; "
              + "\(configs.count) configs x \(rounds) rounds x \(perSet) files, \(setsNeeded) disjoint sets\n")

        // --- run
        var results: [Config: [RunStats]] = [:]
        var setIndex = 0
        var order = configs
        for round in 1...rounds {
            order.shuffle(using: &rng)
            for cfg in order {
                let urls = sets[setIndex]; setIndex += 1
                var st = await runOnce(cfg, urls)
                st.bytes = urls.reduce(0) { $0 + fileSize($1) }
                results[cfg, default: []].append(st)
                print(String(format: "r%d %-22@ %3d files %6.1f MB %7.2fs %7.1f files/s %6.1f MB/s | ok %d partial %d notags %d FAIL %d",
                             round, cfg.name as NSString, st.files, Double(st.bytes) / 1e6, st.seconds, st.filesPerSec, st.mbPerSec,
                             st.complete, st.partial, st.noTags, st.failed))
                fflush(stdout)
            }
        }

        // --- summary
        print("\n=== summary (mean over \(rounds) rounds; sorted by files/s) ===")
        print("config                  files/s   ms/file    MB/s   per-round files/s")
        let rows = configs.map { c -> (Config, Double, Double, Double, [Double]) in
            let rs = results[c]!
            let fps = rs.map(\.filesPerSec)
            let mean = fps.reduce(0, +) / Double(fps.count)
            let mbps = rs.map(\.mbPerSec).reduce(0, +) / Double(rs.count)
            return (c, mean, 1000 / mean, mbps, fps)
        }.sorted { $0.1 > $1.1 }
        for (c, fps, ms, mbps, per) in rows {
            let perStr = per.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            print(String(format: "%-22@ %9.1f %9.1f %7.1f   [%@]", c.name as NSString, fps, ms, mbps, perStr as NSString))
        }
    }

    // MARK: scan (whole-list verification)

    static func scan(_ args: [String]) async {
        let opts = options(args)
        guard let list = opts["--list"], let root = opts["--root"] else { usage() }
        let strategies = (opts["--strategies"] ?? "auto").split(separator: ",").map(String.init)
        let conc = Int(opts["--conc"] ?? "") ?? 16
        let exts = Set((opts["--ext"] ?? "").split(separator: ",").map { $0.lowercased() })
        let limit = Int(opts["--limit"] ?? "")

        var files = loadFiles(list: list, root: root, exts: exts)
        if let limit { files = Array(files.prefix(limit)) }
        print("scanning \(files.count) files, strategies: \(strategies.joined(separator: ", ")), parallel \(conc)\n")

        var problemLines: [String] = []
        for name in strategies {
            let reader = TagReader(strategy: TagReader.Strategy(rawValue: name) ?? .auto, concurrency: conc)
            var complete = 0, partial = 0, noTags = 0, failed = 0
            var fallbackHist: [String: Int] = [:]
            let t0 = DispatchTime.now().uptimeNanoseconds
            for await r in reader.read(urls: files) {
                switch r.status {
                case .complete: complete += 1
                case .partial(let f):
                    partial += 1
                    for field in f { fallbackHist[field, default: 0] += 1 }
                    problemLines.append("\(name)\tpartial\tmissing \(f.joined(separator: "+"))\t\(r.url.path)")
                case .noTags:
                    noTags += 1
                    problemLines.append("\(name)\tnoTags\t\t\(r.url.path)")
                case .failed(let why):
                    failed += 1
                    problemLines.append("\(name)\tfailed\t\(why)\t\(r.url.path)")
                }
            }
            let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            print(String(format: "%-14@ %6d files %7.1fs %6.1f files/s | ok %d partial %d (%@) notags %d FAIL %d",
                         name as NSString, files.count, secs, Double(files.count) / secs,
                         complete, partial,
                         (fallbackHist.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
                            .joined(separator: ", ")) as NSString, noTags, failed))
            fflush(stdout)
        }

        if let out = opts["--problems"], !problemLines.isEmpty {
            try? problemLines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
            print("\nwrote \(problemLines.count) lines to \(out)")
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0)
    }

    static func runOnce(_ cfg: Config, _ urls: [URL]) async -> RunStats {
        var st = RunStats()
        st.files = urls.count
        let t0 = DispatchTime.now().uptimeNanoseconds
        if cfg.strategy == "ffprobe" {
            await withTaskGroup(of: Bool.self) { group in
                var next = 0
                func add() { let u = urls[next]; next += 1; group.addTask { await ffprobe(u) } }
                while next < min(cfg.concurrency, urls.count) { add() }
                while let ok = await group.next() {
                    if ok { st.complete += 1 } else { st.failed += 1 }
                    if next < urls.count { add() }
                }
            }
        } else {
            let reader = TagReader(strategy: TagReader.Strategy(rawValue: cfg.strategy) ?? .hybrid,
                                   concurrency: cfg.concurrency)   // (unknown names fall back to .hybrid above)
            for await r in reader.read(urls: urls) {
                switch r.status {
                case .complete: st.complete += 1
                case .partial: st.partial += 1
                case .noTags: st.noTags += 1
                case .failed: st.failed += 1
                }
            }
        }
        st.seconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        return st
    }

    /// Reference: what the old app does (spawn ffprobe per file).
    static func ffprobe(_ url: URL) async -> Bool {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
                p.arguments = ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: false); return }
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: p.terminationStatus == 0)
            }
        }
    }
}
