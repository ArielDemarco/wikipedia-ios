import Foundation
import MemoryInsight

/// Reporte de memoria de la app anfitriona.
///
/// Único archivo agregado a Wikipedia además de una línea en AppDelegate. Es
/// deliberadamente así: el SDK es una API, y la integración de un cliente
/// debería ser una llamada, no una ceremonia.
enum MemoryInsightProbe {

    /// Espera a que la app levante la UI y cargue contenido antes de medir:
    /// capturar en el arranque daría un proceso a medio construir.
    /// Un reporter por prioridad: la pregunta es si el QoS de la cola cambia
    /// cuánto tiempo se sostienen los locks, que es lo que frena a la app.
    private static let reporters: [(String, MemoryReporter)] = [
        ("utility", MemoryReporter(qos: .utility)),
        ("userInitiated", MemoryReporter(qos: .userInitiated))
    ]

    static func scheduleReport(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Task { await compareQoS() }
        }
    }

    /// Varias muestras por prioridad. La primera de cada una paga el
    /// relevamiento inicial, así que se descarta.
    private static func compareQoS() async {
        var out = "\n████ MemoryInsight · costo por prioridad de cola ████\n"
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
            out += String(format: "  %-14@ lockeado: mediana %.1f ms · min %.1f · max %.1f",
                          name as NSString, ls[ls.count / 2], ls[0], ls[ls.count - 1])
            out += String(format: "   │ total mediana %.1f ms  (%d muestras)\n",
                          ts[ts.count / 2], ls.count)
        }
        emit(out + "████ FIN ████\n")

        if let dump = await reporters[1].1.capture() {
            emit(buildReport(dump))
        }
    }

    private static func buildReport(_ dump: MemoryDump?) -> String {
        var out = "\n████ MemoryInsight · \(ProcessInfo.processInfo.processName) ████\n"
        guard let dump else { return out + "✗ no se pudo capturar\n" }

        out += "  device \(dump.device.model) · \(dump.device.systemVersion)\n"
        out += "  footprint \(dump.footprint.physFootprintBytes.mi_reportBytes)\n"

        out += "\nPor origen (propio, sin lo compartido)\n"
        for b in dump.regions.byOrigin.prefix(10) where b.bytes > 0 {
            out += "  " + mi_pad(b.name, 32) + b.bytes.mi_reportBytes + "\n"
        }

        if let heap = dump.heap {
            out += "\nPor tipo\n"
            for b in heap.byType.prefix(10) {
                out += "  " + mi_pad(String(b.name.prefix(40)), 42)
                     + "\(b.count) · \(b.bytes.mi_reportBytes)\n"
            }
            out += "\n══ Veredicto ══\n"
            let share = Double(heap.totalBytes) / Double(max(dump.footprint.physFootprintBytes, 1))
            out += String(format: "  heap / footprint   : %5.1f%%\n", share * 100)
            out += String(format: "  con nombre de tipo : %5.1f%% del heap\n",
                          heap.classifiedRatio * 100)
        }
        out += String(format: "  costo: mapa %.2f ms · censo %.2f ms · lockeado %.2f ms\n",
                      dump.cost.regionsMillis, dump.cost.censusMillis ?? 0,
                      dump.cost.censusLockedMillis ?? 0)
        if let json = try? dump.jsonData() { out += "  payload: \(json.count) bytes\n" }
        return out + "████ FIN ████\n"
    }

    /// stderr sin buffer: en un device el stdout se pierde con facilidad.
    private static func emit(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
        print(text)
    }
}
