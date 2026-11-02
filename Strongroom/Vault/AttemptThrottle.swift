import Foundation

/// Slows down guessing. A wrong pattern can't be told apart from a new, empty vault,
/// so every "no vault here" result counts as a miss. Opening or creating a vault resets it.
/// Stored in the Keychain, so deleting and reinstalling the app doesn't reset it.
enum AttemptThrottle {
    static let freeMisses = 5
    static let baseDelay: TimeInterval = 30
    static let maxDelay: TimeInterval = 3600
    private static let account = "attempt-throttle"

    private struct State: Codable {
        var misses = 0
        var lockedUntil: Date?
    }

    /// Seconds to wait before another attempt is allowed, or nil if allowed now.
    static func waitTime(now: Date = Date()) -> TimeInterval? {
        guard let until = load().lockedUntil, until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    static func recordMiss(now: Date = Date()) {
        var state = load()
        state.misses += 1
        let over = state.misses - freeMisses
        if over >= 0 {
            let delay = min(baseDelay * pow(2, Double(over)), maxDelay)
            state.lockedUntil = now.addingTimeInterval(delay)
        }
        save(state)
    }

    static func reset() {
        save(State())
    }

    private static func load() -> State {
        guard let data = try? Keychain.read(account),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private static func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? Keychain.write(data, account: account)
    }
}
