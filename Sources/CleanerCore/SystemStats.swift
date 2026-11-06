import Foundation
import IOKit.ps

public struct StatsSnapshot: Sendable, Equatable {
  public var diskFreeBytes: Int64
  public var diskTotalBytes: Int64
  public var memoryUsedFraction: Double
  public var cpuFraction: Double
  public var batteryFraction: Double?
  public init(diskFreeBytes: Int64, diskTotalBytes: Int64, memoryUsedFraction: Double, cpuFraction: Double, batteryFraction: Double?) {
    self.diskFreeBytes = diskFreeBytes
    self.diskTotalBytes = diskTotalBytes
    self.memoryUsedFraction = memoryUsedFraction
    self.cpuFraction = cpuFraction
    self.batteryFraction = batteryFraction
  }
}

public struct CPUTicks: Sendable, Equatable {
  public var busy: UInt64
  public var total: UInt64
  public init(busy: UInt64, total: UInt64) {
    self.busy = busy
    self.total = total
  }
}

public final class SystemStats: @unchecked Sendable {
  private let volume: URL
  private let lock = NSLock()
  private var previous: CPUTicks?

  public init(volume: URL) { self.volume = volume }

  public func sample() -> StatsSnapshot {
    let (free, total) = disk()
    return StatsSnapshot(
      diskFreeBytes: min(free, total), diskTotalBytes: total,
      memoryUsedFraction: memory(), cpuFraction: cpu(), batteryFraction: battery())
  }

  public static func cpuFraction(previous: CPUTicks, current: CPUTicks) -> Double {
    guard current.total > previous.total, current.busy >= previous.busy else { return 0 }
    let f = Double(current.busy - previous.busy) / Double(current.total - previous.total)
    return min(max(f, 0), 1)
  }

  private func disk() -> (free: Int64, total: Int64) {
    let v = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    let total = Int64(v?.volumeTotalCapacity ?? 0)
    return (max(v?.volumeAvailableCapacityForImportantUsage ?? 0, 0), total)
  }

  private func memory() -> Double {
    var info = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    var pageSize: vm_size_t = 0
    guard kr == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
    let used = (UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * UInt64(pageSize)
    let physical = ProcessInfo.processInfo.physicalMemory
    guard physical > 0 else { return 0 }
    return min(max(Double(used) / Double(physical), 0), 1)
  }

  private func cpu() -> Double {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let t = info.cpu_ticks  // (user, system, idle, nice)
    let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
    let now = CPUTicks(busy: busy, total: busy + UInt64(t.2))
    lock.lock(); defer { lock.unlock() }
    defer { previous = now }
    guard let prev = previous else { return 0 }
    return Self.cpuFraction(previous: prev, current: now)
  }

  private func battery() -> Double? {
    let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
    for source in list {
      // Description is owned by the blob (Get rule), so no release needed.
      guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
        d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
      else { continue }
      return Swift.min(Swift.max(Double(cur) / Double(max), 0), 1)
    }
    return nil
  }
}
