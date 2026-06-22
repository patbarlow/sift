import Foundation
import Combine

/// Aggregates LLM token usage (including prompt-cache reads/writes) reported by
/// the API clients, for an at-a-glance view of spend and cache savings. Totals
/// are kept for the current day and for all time, and persisted across launches.
/// The clients write to it as a side effect, so it adds no plumbing to the call
/// path.
@MainActor
final class LLMUsageStore: ObservableObject {
    static let shared = LLMUsageStore()

    struct Totals: Codable, Equatable {
        var inputTokens = 0          // uncached input
        var outputTokens = 0
        var cacheReadTokens = 0      // input served from cache — the savings
        var cacheCreationTokens = 0  // input written into the cache
        var calls = 0

        /// Total input processed = uncached + cache read + cache write.
        var totalInput: Int { inputTokens + cacheReadTokens + cacheCreationTokens }

        /// Fraction of input served from cache.
        var cacheHitRate: Double {
            totalInput > 0 ? Double(cacheReadTokens) / Double(totalInput) : 0
        }
    }

    @Published private(set) var lifetime: Totals
    @Published private(set) var today: Totals

    /// True once any prompt-cache activity has been seen. Used to decide whether
    /// the usage card is worth showing — providers that don't report caching
    /// never set this, so the card simply doesn't appear.
    var hasCacheData: Bool { lifetime.cacheReadTokens + lifetime.cacheCreationTokens > 0 }

    private static let lifetimeKey = "sift.usage.lifetime"
    private static let todayKey = "sift.usage.today"
    private static let todayDayKey = "sift.usage.todayDay"

    private init() {
        let defaults = UserDefaults.standard
        lifetime = Self.decode(defaults.data(forKey: Self.lifetimeKey)) ?? Totals()
        // Keep the daily bucket only if it belongs to today.
        if defaults.string(forKey: Self.todayDayKey) == Self.dayStamp() {
            today = Self.decode(defaults.data(forKey: Self.todayKey)) ?? Totals()
        } else {
            today = Totals()
        }
    }

    func record(input: Int, output: Int, cacheRead: Int, cacheCreation: Int) {
        if UserDefaults.standard.string(forKey: Self.todayDayKey) != Self.dayStamp() {
            today = Totals()   // rolled past midnight since the last record
        }
        Self.add(&lifetime, input, output, cacheRead, cacheCreation)
        Self.add(&today, input, output, cacheRead, cacheCreation)
        persist()
    }

    private static func add(_ t: inout Totals, _ input: Int, _ output: Int, _ cacheRead: Int, _ cacheCreation: Int) {
        t.inputTokens += input
        t.outputTokens += output
        t.cacheReadTokens += cacheRead
        t.cacheCreationTokens += cacheCreation
        t.calls += 1
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(lifetime), forKey: Self.lifetimeKey)
        defaults.set(try? JSONEncoder().encode(today), forKey: Self.todayKey)
        defaults.set(Self.dayStamp(), forKey: Self.todayDayKey)
    }

    private static func decode(_ data: Data?) -> Totals? {
        data.flatMap { try? JSONDecoder().decode(Totals.self, from: $0) }
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
