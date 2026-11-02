import Foundation

/// A drawn unlock pattern on a 5×5 grid. Dots are numbered 0...24, row by row.
struct Pattern: Equatable, Sendable {
    static let gridSize = 5
    static let minimumDots = 6

    enum ValidationError: Error, Equatable {
        case tooShort
        case noDirectionChange
        case invalidDot
        case repeatedDot
    }

    let dots: [Int]

    /// Stable text form fed into the KDF, e.g. "0-6-12-13-18-24".
    var encoded: String { dots.map(String.init).joined(separator: "-") }

    func validate() throws {
        guard dots.allSatisfy({ (0..<Self.gridSize * Self.gridSize).contains($0) }) else {
            throw ValidationError.invalidDot
        }
        guard Set(dots).count == dots.count else { throw ValidationError.repeatedDot }
        guard dots.count >= Self.minimumDots else { throw ValidationError.tooShort }
        let directions = zip(dots, dots.dropFirst()).map { Self.direction(from: $0, to: $1) }
        guard Set(directions.map { "\($0.dx),\($0.dy)" }).count > 1 else {
            throw ValidationError.noDirectionChange
        }
    }

    /// Dots lying exactly on the straight segment between two dots, in drawing order.
    /// Like Android's lock screen, crossing a dot selects it.
    static func dotsBetween(_ a: Int, _ b: Int) -> [Int] {
        let (ax, ay) = (a % gridSize, a / gridSize)
        let (bx, by) = (b % gridSize, b / gridSize)
        let (dx, dy) = (bx - ax, by - ay)
        let steps = gcd(abs(dx), abs(dy))
        guard steps > 1 else { return [] }
        return (1..<steps).map { i in
            (ay + dy / steps * i) * gridSize + (ax + dx / steps * i)
        }
    }

    private static func direction(from a: Int, to b: Int) -> (dx: Int, dy: Int) {
        let dx = b % gridSize - a % gridSize
        let dy = b / gridSize - a / gridSize
        let g = max(gcd(abs(dx), abs(dy)), 1)
        return (dx / g, dy / g)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}

extension Pattern.ValidationError {
    var message: String {
        switch self {
        case .tooShort: "Connect at least \(Pattern.minimumDots) dots."
        case .noDirectionChange: "Change direction at least once."
        case .invalidDot, .repeatedDot: "That pattern isn't valid. Try again."
        }
    }
}
