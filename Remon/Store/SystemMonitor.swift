import Foundation
import Observation

struct SystemPoint: Identifiable, Hashable, Sendable {
    var date: Date
    var cpu: Double
    var gpu: Double
    var memory: Double
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var id: Date { date }
}

/// Live CPU / GPU / memory / thermal state, sampled every 2 seconds off the main thread.
@MainActor @Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    static let historyLength = 150 // 5 minutes at 2 s

    private(set) var latest: SystemSnapshot?
    private(set) var history: [SystemPoint] = []
    private(set) var peakCPUTemperature: Double = 0

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onSample: ((SystemSnapshot) -> Void)?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.sampler.sample()
                self.ingest(snapshot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func ingest(_ s: SystemSnapshot) {
        latest = s
        let cpuTemp = s.temperature(.cpu)
        if let cpuTemp { peakCPUTemperature = max(peakCPUTemperature, cpuTemp) }
        history.append(SystemPoint(date: s.date, cpu: s.cpuTotal, gpu: s.gpuUtilization ?? 0, memory: s.memory.fraction,
                                   cpuTemperature: cpuTemp, gpuTemperature: s.temperature(.gpu)))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        onSample?(s)
    }
}
