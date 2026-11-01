import SwiftUI
import Darwin
import IOKit

// MARK: - Monitor

/// One reading of CPU and GPU load. Loads are 0...1.
struct SystemStats {
    var cpu = 0.0
    var cpuUser = 0.0
    var cpuSystem = 0.0
    /// Per logical core, in the kernel's CPU order.
    var cores: [Double] = []
    /// nil when the GPU's statistics can't be read.
    var gpu: Double?
    /// System memory the GPU is currently using (Apple Silicon shares RAM with the GPU).
    var gpuMemoryBytes: Int64?
}

enum CoreKind {
    case efficiency, performance
}

/// Samples CPU load (Mach host statistics) and GPU load (IOAccelerator performance
/// statistics) once a second. Neither source needs root or any permission prompt.
final class SystemMonitor: ObservableObject {
    /// Number of one-second samples kept for the history graphs.
    static let historyLength = 60

    @Published private(set) var stats = SystemStats()
    /// Oldest first.
    @Published private(set) var cpuHistory: [Double] = []
    /// Oldest first.
    @Published private(set) var gpuHistory: [Double] = []

    let chipName: String
    let coreCount = ProcessInfo.processInfo.processorCount
    /// Kind of each logical core, or empty if the layout couldn't be read.
    let coreKinds: [CoreKind]
    let gpuCoreCount: Int?

    private var previousTicks: [CoreTicks]
    private var timer: Timer?

    init() {
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? "CPU"
        coreKinds = Self.readCoreKinds()
        gpuCoreCount = Self.readGPUCoreCount()
        previousTicks = Self.readCoreTicks()

        // Sampling continuously (rather than only while the tab is open) keeps the
        // graphs full when you open the notch; each sample costs well under a millisecond.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        var next = SystemStats()

        let ticks = Self.readCoreTicks()
        if ticks.count == previousTicks.count, !ticks.isEmpty {
            var user = 0.0, system = 0.0, total = 0.0
            next.cores = zip(ticks, previousTicks).map { now, before in
                // Tick counters are 32-bit and wrap, so subtract with wrapping.
                let u = Double(now.user &- before.user) + Double(now.nice &- before.nice)
                let s = Double(now.system &- before.system)
                let t = u + s + Double(now.idle &- before.idle)
                user += u; system += s; total += t
                return t > 0 ? (u + s) / t : 0
            }
            if total > 0 {
                next.cpuUser = user / total
                next.cpuSystem = system / total
                next.cpu = (user + system) / total
            }
        }
        previousTicks = ticks

        if let gpu = Self.readGPU() {
            next.gpu = gpu.utilization
            next.gpuMemoryBytes = gpu.memoryBytes
        }

        stats = next
        cpuHistory = Self.appending(next.cpu, to: cpuHistory)
        if let gpu = next.gpu { gpuHistory = Self.appending(gpu, to: gpuHistory) }
    }

    private static func appending(_ value: Double, to history: [Double]) -> [Double] {
        (history + [value]).suffix(historyLength)
    }

    // MARK: CPU

    private struct CoreTicks {
        var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    }

    /// Fetched once: each `mach_host_self()` call adds a port reference.
    private static let host = mach_host_self()

    private static func readCoreTicks() -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                             idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE))
        }
    }

    /// Reads each core's cluster type ("E" or "P") from the device tree, indexed by logical CPU id.
    private static func readCoreKinds() -> [CoreKind] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var kinds: [Int: CoreKind] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let id = property(entry, "logical-cpu-id") as? NSNumber,
                  let cluster = (property(entry, "cluster-type") as? Data)?.first
            else { continue }
            kinds[id.intValue] = cluster == UInt8(ascii: "E") ? .efficiency : .performance
        }
        let ordered = (0..<kinds.count).compactMap { kinds[$0] }
        return ordered.count == kinds.count ? ordered : []
    }

    // MARK: GPU

    private static func readGPU() -> (utilization: Double, memoryBytes: Int64?)? {
        var result: (utilization: Double, memoryBytes: Int64?)?
        forEachAccelerator { service in
            guard let perf = property(service, "PerformanceStatistics") as? [String: Any],
                  let percent = (perf["Device Utilization %"] ?? perf["GPU Activity(%)"]) as? NSNumber
            else { return }
            let utilization = min(max(percent.doubleValue / 100, 0), 1)
            // Macs with more than one GPU: report the busiest.
            if utilization >= result?.utilization ?? -1 {
                result = (utilization, (perf["In use system memory"] as? NSNumber)?.int64Value)
            }
        }
        return result
    }

    private static func readGPUCoreCount() -> Int? {
        var count: Int?
        forEachAccelerator { service in
            if count == nil { count = (property(service, "gpu-core-count") as? NSNumber)?.intValue }
        }
        return count
    }

    private static func forEachAccelerator(_ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    // MARK: Helpers

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Colors

extension Color {
    /// Series colors, validated against the black notch for contrast and color-blind separation.
    static let cpuSeries = Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255) // #3987e5
    static let gpuSeries = Color(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255) // #d95926
}

private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

// MARK: - Views

struct SystemView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cpuCard
            gpuCard.frame(width: 250)
        }
    }

    private var cpuCard: some View {
        let stats = monitor.stats
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "CPU", color: .cpuSeries,
                       detail: "\(monitor.chipName) · \(monitor.coreCount) cores")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                BigValue(text: percent(stats.cpu))
                Text("User \(percent(stats.cpuUser))  ·  System \(percent(stats.cpuSystem))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HistoryGraph(values: monitor.cpuHistory, color: .cpuSeries, name: "CPU")
                .frame(height: 64)
                .padding(.bottom, 4)
            CoreClusters(loads: stats.cores, kinds: monitor.coreKinds)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private var gpuCard: some View {
        let stats = monitor.stats
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "GPU", color: .gpuSeries,
                       detail: monitor.gpuCoreCount.map { "\($0)-core" } ?? "")
            BigValue(text: stats.gpu.map(percent) ?? "–")
            if stats.gpu != nil || !monitor.gpuHistory.isEmpty {
                HistoryGraph(values: monitor.gpuHistory, color: .gpuSeries, name: "GPU")
                    .frame(height: 64)
                    .padding(.bottom, 4)
            } else {
                Text("GPU statistics aren't available on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 68, alignment: .topLeading)
            }
            HStack {
                Text("Memory in use")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stats.gpuMemoryBytes.map { $0.formatted(.byteCount(style: .memory)) } ?? "–")
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))

            Spacer(minLength: 0)

            Toggle("Show in closed notch", isOn: $vm.showSystemStatsInNotch)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }
}

private struct CardHeader: View {
    let title: String
    let color: Color
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

private struct BigValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: text)
    }
}

/// Load over the last minute on a fixed 0–100% scale, newest at the right edge.
/// Hovering shows the value under the pointer.
private struct HistoryGraph: View {
    let values: [Double]
    let color: Color
    let name: String

    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let hovered = hoverX.flatMap { GraphPath.index(nearest: $0, count: values.count, in: rect) }

            ZStack(alignment: .topLeading) {
                // Recessive scale: baseline and a dashed 50% line.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: rect.midY))
                    p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                }
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)
                    .offset(y: rect.maxY - 1)

                GraphPath(values: values, filled: true)
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
                GraphPath(values: values, filled: false)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if let i = hovered {
                    let point = GraphPath.point(i, count: values.count, value: values[i], in: rect)
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1, height: rect.height)
                        .offset(x: point.x - 0.5)
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .position(point)
                    // Sit the readout in whichever half of the graph the line isn't in.
                    readout(for: i)
                        .fixedSize()
                        .position(x: min(max(point.x, 44), rect.maxX - 44),
                                  y: point.y < rect.midY ? rect.maxY - 10 : 10)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(name) load, last minute")
        .accessibilityValue(values.last.map(percent) ?? "No data")
    }

    private func readout(for index: Int) -> some View {
        let age = values.count - 1 - index
        return Text("\(percent(values[index])) · \(age == 0 ? "now" : "\(age)s ago")")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(white: 0.16)))
    }
}

/// Line (or filled area) through one-second samples; one slot per second of history.
private struct GraphPath: Shape {
    var values: [Double]
    var filled: Bool

    private static var slotCount: CGFloat { CGFloat(SystemMonitor.historyLength - 1) }

    static func point(_ index: Int, count: Int, value: Double, in rect: CGRect) -> CGPoint {
        let step = rect.width / slotCount
        return CGPoint(x: rect.maxX - CGFloat(count - 1 - index) * step,
                       y: rect.maxY - CGFloat(min(max(value, 0), 1)) * rect.height)
    }

    static func index(nearest x: CGFloat, count: Int, in rect: CGRect) -> Int? {
        guard count > 0 else { return nil }
        let fromRight = Int(((rect.maxX - x) / (rect.width / slotCount)).rounded())
        let index = count - 1 - fromRight
        return (0..<count).contains(index) ? index : nil
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let points = values.indices.map { Self.point($0, count: values.count, value: values[$0], in: rect) }
        path.addLines(points)
        if filled {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Per-core meters, grouped into efficiency and performance clusters when the layout is known.
private struct CoreClusters: View {
    let loads: [Double]
    let kinds: [CoreKind]

    private static let barSpacing: CGFloat = 4
    private static let groupSpacing: CGFloat = 16

    private struct Core {
        let number: Int
        let load: Double
    }

    private struct Group {
        let title: String
        let cores: [Core]
        var average: Double { cores.map(\.load).reduce(0, +) / Double(max(cores.count, 1)) }
    }

    private var groups: [Group] {
        guard kinds.count == loads.count else {
            return [Group(title: "Cores", cores: loads.enumerated().map { Core(number: $0.offset + 1, load: $0.element) })]
        }
        let named: [(CoreKind, String)] = [(.efficiency, "Efficiency"), (.performance, "Performance")]
        return named.compactMap { kind, title in
            let clusterLoads = zip(kinds, loads).filter { $0.0 == kind }.map(\.1)
            guard !clusterLoads.isEmpty else { return nil }
            return Group(title: title, cores: clusterLoads.enumerated().map { Core(number: $0.offset + 1, load: $0.element) })
        }
    }

    var body: some View {
        let groups = groups
        GeometryReader { geo in
            let gaps = CGFloat(max(loads.count - groups.count, 0)) * Self.barSpacing
                + CGFloat(max(groups.count - 1, 0)) * Self.groupSpacing
            let barWidth = max((geo.size.width - gaps) / CGFloat(max(loads.count, 1)), 2)

            HStack(alignment: .top, spacing: Self.groupSpacing) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Text(group.title.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                            Text(percent(group.average))
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        .fixedSize()

                        HStack(spacing: Self.barSpacing) {
                            ForEach(group.cores, id: \.number) { core in
                                CoreMeter(load: core.load)
                                    .frame(width: barWidth)
                                    .help("\(group.title) core \(core.number) · \(percent(core.load))")
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 40)
    }
}

/// Vertical meter: the track is a dim step of the CPU hue, the fill rises from the baseline.
private struct CoreMeter: View {
    let load: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.cpuSeries.opacity(0.16)
                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                    .fill(Color.cpuSeries)
                    .frame(height: geo.size.height * CGFloat(min(max(load, 0), 1)))
                    .animation(.easeOut(duration: 0.3), value: load)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

/// CPU and GPU load on either side of the closed notch (opt-in from the System tab).
struct SystemLiveActivity: View {
    @EnvironmentObject var monitor: SystemMonitor
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ear(label: "CPU", value: monitor.stats.cpu, color: .cpuSeries)
            Color.clear.frame(width: notchWidth)
            ear(label: "GPU", value: monitor.stats.gpu, color: .gpuSeries)
        }
    }

    private func ear(label: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 4) {
            // Mini meter: identity by hue, load by height.
            ZStack(alignment: .bottom) {
                Capsule().fill(color.opacity(0.25))
                Capsule().fill(color)
                    .frame(height: 14 * CGFloat(min(max(value ?? 0, 0), 1)))
            }
            .frame(width: 3, height: 14)
            .clipShape(Capsule())
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            Text(value.map(percent) ?? "–")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}
