import Foundation
import MemoryInsight

/// Memory report for the host app.
///
/// The only file added to Wikipedia besides one line in AppDelegate. That is
/// deliberate: the SDK is an API, and a client's integration should be a call,
/// not a ceremony.
enum MemoryInsightProbe {

    /// One reporter per priority: the question is whether the queue's QoS
    /// changes how long the locks are held, which is what stalls the app.
    private static let reporters: [(String, MemoryReporter)] = [
        ("utility", MemoryReporter(qos: .utility)),
        ("userInitiated", MemoryReporter(qos: .userInitiated))
    ]

    /// Waits for the app to bring up its UI and load content before measuring:
    /// capturing at launch would sample a half-built process.
    static func scheduleReport(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Task { await trackWhileBrowsing() }
        }
    }

    /// Takes a baseline and then keeps diffing against it while someone uses
    /// the app.
    ///
    /// This is the case the whole project is for: not "how much memory is there"
    /// but "what grew, and where did it come from". A map view is the sharpest
    /// example available in this app -- tiles are graphics memory, so the heap
    /// census should stay flat while the region map moves.
    private static func trackWhileBrowsing(samples: Int = 30,
                                           every seconds: TimeInterval = 5) async {
        let reporter = reporters[1].1      // .userInitiated: the cheaper QoS
        emit("[baseline start]")
        guard let baseline = await reporter.capture() else {
            emit("\n✗ baseline capture failed\n")
            return
        }
        emit(header("baseline", baseline))

        for step in 1...samples {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            emit("[capture \(step) start]")
            guard let now = await reporter.capture() else {
                emit("[capture \(step) returned nil]")
                continue
            }
            emit("[capture \(step) ok]")

            var out = header("t+\(Int(Double(step) * seconds))s", now)
            if let diff = try? MemoryDumpDiff.between(baseline, now) {
                out += diff.formattedReport(topN: 8)
            }
            emit(out)
        }
        emit("\n████ END ████\n")
    }

    private static func header(_ label: String, _ dump: MemoryDump) -> String {
        var out = "\n████ \(label) ████\n"
        out += "  footprint \(dump.footprint.physFootprintBytes.mi_reportBytes)"
        if let heap = dump.heap {
            out += " · heap \(heap.totalBytes.mi_reportBytes)"
            let share = Double(heap.totalBytes) / Double(max(dump.footprint.physFootprintBytes, 1))
            out += String(format: " (%.0f%% of footprint)", share * 100)
        }
        if let gpu = dump.footprint.gpuAllocatedBytes {
            out += " · GPU \(gpu.mi_reportBytes)"
        }
        return out + "\n"
    }

    /// Several samples per priority. The first of each pays for the initial
    /// survey, so it is discarded.
    private static func compareQoS() async {
        var out = "\n████ MemoryInsight · cost by queue priority ████\n"
        for (name, reporter) in reporters {
            var locked: [Double] = []
            var total: [Double] = []
            for i in 0..<6 {
                guard let dump = await reporter.capture() else { continue }
                if i == 0 { continue }
                locked.append(dump.cost.censusLockedMillis ?? 0)
                total.append(dump.cost.censusMillis ?? 0)
            }
            guard !locked.isEmpty else { continue }
            let ls = locked.sorted(), ts = total.sorted()
            out += String(format: "  %-14@ locked: median %.1f ms · min %.1f · max %.1f",
                          name as NSString, ls[ls.count / 2], ls[0], ls[ls.count - 1])
            out += String(format: "   │ total median %.1f ms  (%d samples)\n",
                          ts[ts.count / 2], ls.count)
        }
        emit(out + "████ END ████\n")

        if let dump = await reporters[1].1.capture() {
            emit(buildReport(dump))
        }
    }

    private static func buildReport(_ dump: MemoryDump?) -> String {
        var out = "\n████ MemoryInsight · \(ProcessInfo.processInfo.processName) ████\n"
        guard let dump else { return out + "✗ capture failed\n" }

        out += "  device \(dump.device.model) · \(dump.device.systemVersion)\n"
        out += "  footprint \(dump.footprint.physFootprintBytes.mi_reportBytes)\n"

        out += "\nBy origin (private, excluding shared)\n"
        for b in dump.regions.byOrigin.prefix(10) where b.bytes > 0 {
            out += "  " + mi_pad(b.name, 32) + b.bytes.mi_reportBytes + "\n"
        }

        if let heap = dump.heap {
            out += "\nBy type\n"
            for b in heap.byType.prefix(10) {
                out += "  " + mi_pad(String(b.name.prefix(40)), 42)
                     + "\(b.count) · \(b.bytes.mi_reportBytes)\n"
            }
            out += "\n══ Verdict ══\n"
            let share = Double(heap.totalBytes) / Double(max(dump.footprint.physFootprintBytes, 1))
            out += String(format: "  heap / footprint   : %5.1f%%\n", share * 100)
            out += String(format: "  named with a type  : %5.1f%% of the heap\n",
                          heap.classifiedRatio * 100)
        }
        out += String(format: "  cost: map %.2f ms · census %.2f ms · locked %.2f ms\n",
                      dump.cost.regionsMillis, dump.cost.censusMillis ?? 0,
                      dump.cost.censusLockedMillis ?? 0)
        if let json = try? dump.jsonData() { out += "  payload: \(json.count) bytes\n" }
        return out + "████ END ████\n"
    }

    /// Unbuffered stderr: on a device stdout is easily lost.
    private static func emit(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
        print(text)
    }
}
