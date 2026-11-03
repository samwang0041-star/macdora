import Foundation
import Darwin

struct HostPerformanceProfile: Equatable, Sendable {
    let guestMemoryMB: Int
    let guestCPUCount: Int
    let guestRefreshRate: Int

    static func resolve(physicalMemoryBytes: UInt64, performanceCores: Int) -> HostPerformanceProfile {
        let memoryGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
        if memoryGB < 10 {
            return HostPerformanceProfile(guestMemoryMB: 4096, guestCPUCount: 4, guestRefreshRate: 60)
        }
        if memoryGB < 24 {
            return HostPerformanceProfile(
                guestMemoryMB: 6144,
                guestCPUCount: min(8, max(4, performanceCores)),
                guestRefreshRate: 60
            )
        }
        let memory = memoryGB >= 32 ? 12288 : 9216
        return HostPerformanceProfile(
            guestMemoryMB: memory,
            guestCPUCount: min(8, max(4, performanceCores)),
            guestRefreshRate: memoryGB >= 32 && performanceCores >= 6 ? 120 : 60
        )
    }

    static func current() -> HostPerformanceProfile {
        resolve(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            performanceCores: performanceCoreCount()
        )
    }

    private static func performanceCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return ProcessInfo.processInfo.processorCount
    }
}
