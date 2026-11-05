import Foundation
import StorebenchCore
import SwiftUI

/// How much Storebench keeps in memory between screens on this Mac, and how long a read from App Store Connect is reused.
struct PerformanceSettings: View {
    let model: LibraryModel
    @State private var usedBytes: Int?
    @State private var working = false
    @State private var status = ""
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        let policy = model.cachePolicy
        StorebenchFormSection("Performance") {
            StorebenchPicker("Cache", selection: Binding(get: { policy.level }, set: { level in var next = policy; next.level = level; choose(next) }),
                             hint: "Applies at once and is remembered on this Mac.") {
                selectionOptions(CachePolicy.Level.allCases) { SelectionOption($0.title, value: $0) }
            }
            // Changing the budget or lifetime of any level makes it Custom with both current values.
            StorebenchPicker("Memory budget", selection: Binding(get: { policy.memoryMB(physicalMemory: physicalMemory) }, set: { customize(policy, memory: $0) })) {
                selectionOptions(CachePolicy.memoryChoices) { SelectionOption(Self.memory($0), value: $0) }
            }
            StorebenchPicker("Reuse App Store Connect reads for", selection: Binding(get: { policy.lifetimeMinutes(physicalMemory: physicalMemory) }, set: { customize(policy, minutes: $0) })) {
                selectionOptions(CachePolicy.lifetimeChoices) { SelectionOption(Self.minutes($0), value: $0) }
            }
            StorebenchTextSlot(text: detail(policy), height: 52, font: .sbCallout, color: StorebenchTheme.muted)
            Text("Storebench keeps recent reads, saved versions and release status in memory, so the next screen or Release step opens without waiting, and saves each screen's last read so the next launch shows it at once. Refresh on any screen reads App Store Connect again, and every Publish review always reads Apple itself. Credentials are never part of this cache. Clear Cache removes the cached and saved reads; drafts, history and your choices are kept. When macOS runs low on memory, Storebench frees the memory cache whatever this setting allows.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchFeedback(text: status, height: 40, error: false)
            if model.session != nil {
                StorebenchFormFooter {
                    Button("Clear Cache") { Task { await clear() } }.help("Clear Cached and Saved Screen Reads").accessibilityLabel("Clear Cache").storebenchWorking(working)
                }
            }
        }
        .task(id: "\(model.session.map { String(describing: ObjectIdentifier($0)) } ?? "")/\(policy.level.rawValue)/\(policy.customMemoryMB)/\(policy.customLifetimeMinutes)") { await measure() }
    }

    private func choose(_ policy: CachePolicy) {
        guard policy != model.cachePolicy else { return }
        model.cachePolicy = policy; policy.save(in: .standard)
    }
    private func customize(_ policy: CachePolicy, memory: Int? = nil, minutes: Int? = nil) {
        choose(CachePolicy(level: .custom, customMemoryMB: memory ?? policy.memoryMB(physicalMemory: physicalMemory),
                           customLifetimeMinutes: minutes ?? policy.lifetimeMinutes(physicalMemory: physicalMemory)))
    }
    private func detail(_ policy: CachePolicy) -> String {
        let size = Self.memory(Int(physicalMemory / 1_073_741_824) * 1_024)
        let chosen = policy.level == .automatic ? "Automatic uses \(policy.resolved(physicalMemory: physicalMemory).title) for this Mac's \(size) of memory. " : ""
        let used = usedBytes.map { " About \(Self.amount($0)) is in use now." } ?? ""
        return chosen + "Up to \(Self.memory(policy.memoryMB(physicalMemory: physicalMemory))) in memory; reads are reused for \(Self.minutes(policy.lifetimeMinutes(physicalMemory: physicalMemory)))." + used
    }
    private func measure() async {
        guard let session = model.session else { usedBytes = nil; return }
        // The new budget may still be applying; apply it here too so the size read follows it.
        await session.applyCachePolicy(model.cachePolicy)
        usedBytes = await model.cachedMemoryBytes()
    }
    private func clear() async {
        guard !working, model.session != nil else { return }
        working = true; defer { working = false }
        await model.clearCachedReads()
        usedBytes = await model.cachedMemoryBytes(); status = "Cache cleared. Each screen reads App Store Connect again when it opens."
    }

    private static func memory(_ megabytes: Int) -> String {
        guard megabytes >= 1_024 else { return "\(megabytes) MB" }
        let gigabytes = Double(megabytes) / 1_024
        return gigabytes == gigabytes.rounded() ? "\(Int(gigabytes)) GB" : String(format: "%.1f GB", gigabytes)
    }
    private static func minutes(_ value: Int) -> String { value == 1 ? "1 minute" : "\(value) minutes" }
    private static func amount(_ bytes: Int) -> String { bytes < 1_048_576 ? "\(max(0, bytes / 1_024)) KB" : memory(bytes / 1_048_576) }
}
