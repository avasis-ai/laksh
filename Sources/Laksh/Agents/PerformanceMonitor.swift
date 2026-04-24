import Foundation
import Combine

/// Lightweight system performance monitor
/// Samples on a background thread, publishes on main via Task.
final class PerformanceMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var memoryUsage: Double = 0
    @Published var memoryUsedGB: Double = 0
    let memoryTotalGB: Double
    
    private var timer: Timer?
    private let bgQueue = DispatchQueue(label: "laksh.perfmon", qos: .utility)
    private let sampleInterval: TimeInterval = 3.0
    
    // Only touched from bgQueue — no synchronization needed
    private var previousCPUInfo: host_cpu_load_info?
    
    init() {
        memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func start() {
        guard timer == nil else { return }
        
        sample()
        
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    /// All heavy work on background queue, publish back to main.
    private func sample() {
        let totalGB = memoryTotalGB
        bgQueue.async { [weak self] in
            guard let self else { return }
            
            // CPU
            var cpuInfo = host_cpu_load_info()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            
            let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
                }
            }
            
            var cpuValue: Double = 0
            if result == KERN_SUCCESS {
                if let previous = self.previousCPUInfo {
                    // Cast to Double before subtracting to avoid unsigned underflow.
                    let userDiff = Double(cpuInfo.cpu_ticks.0) - Double(previous.cpu_ticks.0)
                    let systemDiff = Double(cpuInfo.cpu_ticks.1) - Double(previous.cpu_ticks.1)
                    let idleDiff = Double(cpuInfo.cpu_ticks.2) - Double(previous.cpu_ticks.2)
                    let niceDiff = Double(cpuInfo.cpu_ticks.3) - Double(previous.cpu_ticks.3)
                    
                    let total = userDiff + systemDiff + idleDiff + niceDiff
                    if total > 0 {
                        cpuValue = ((userDiff + systemDiff) / total) * 100
                    }
                }
                self.previousCPUInfo = cpuInfo
            }
            
            // Memory
            var stats = vm_statistics64()
            var memCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            
            var memValue: Double = 0
            var memGBValue: Double = 0
            
            let memResult = withUnsafeMutablePointer(to: &stats) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(memCount)) { intPtr in
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &memCount)
                }
            }
            
            if memResult == KERN_SUCCESS {
                let pageSize = Double(vm_kernel_page_size)
                let active = Double(stats.active_count) * pageSize
                let wired = Double(stats.wire_count) * pageSize
                let compressed = Double(stats.compressor_page_count) * pageSize
                
                let used = active + wired + compressed
                memGBValue = used / 1_073_741_824
                memValue = (memGBValue / totalGB) * 100
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.cpuUsage = cpuValue
                self?.memoryUsage = memValue
                self?.memoryUsedGB = memGBValue
            }
        }
    }
}

import SwiftUI

// MARK: - Performance indicator semantic colors (derived from design system)

private extension Color {
    /// Threshold bar color: normal operation
    static let perfNormal = Color.clayText.opacity(0.35)
    /// Threshold bar color: warning (>50% CPU / >70% MEM)
    static let perfWarning = Color(red: 0.90, green: 0.65, blue: 0.30)
    /// Threshold bar color: danger (>80% CPU / >85% MEM)
    static let perfDanger = Color(red: 0.90, green: 0.35, blue: 0.30)
}

private extension Font {
    /// 8pt medium — micro-labels inside the performance bar
    static let perfMicro = Font.system(size: 8, weight: .medium)
}

/// Compact performance display for sidebar - subtle, non-distracting
struct PerformanceIndicator: View {
    @ObservedObject var monitor: PerformanceMonitor
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // CPU indicator
            HStack(spacing: 4) {
                Text("CPU")
                    .font(.perfMicro)
                    .foregroundStyle(Color.clayTextDim.opacity(0.6))
                miniBar(value: monitor.cpuUsage / 100, color: cpuColor)
                if isHovered {
                    Text("\(Int(monitor.cpuUsage))%")
                        .font(ClayFont.monoSmall)
                        .foregroundStyle(Color.clayTextDim)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            
            // Memory indicator
            HStack(spacing: 4) {
                Text("MEM")
                    .font(.perfMicro)
                    .foregroundStyle(Color.clayTextDim.opacity(0.6))
                miniBar(value: monitor.memoryUsage / 100, color: memColor)
                if isHovered {
                    Text(String(format: "%.1fG", monitor.memoryUsedGB))
                        .font(ClayFont.monoSmall)
                        .foregroundStyle(Color.clayTextDim)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .help("CPU: \(Int(monitor.cpuUsage))% • RAM: \(String(format: "%.1f", monitor.memoryUsedGB))/\(String(format: "%.0f", monitor.memoryTotalGB))GB")
    }
    
    private func miniBar(value: Double, color: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.claySurface)
                .frame(width: 32, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: max(2, 32 * CGFloat(min(1, value))), height: 4)
                .shadow(color: value > 0.7 ? color.opacity(0.4) : .clear, radius: 2)
        }
    }
    
    private var cpuColor: Color {
        if monitor.cpuUsage > 80 { return .perfDanger }
        if monitor.cpuUsage > 50 { return .perfWarning }
        return .perfNormal
    }
    
    private var memColor: Color {
        if monitor.memoryUsage > 85 { return .perfDanger }
        if monitor.memoryUsage > 70 { return .perfWarning }
        return .perfNormal
    }
}
