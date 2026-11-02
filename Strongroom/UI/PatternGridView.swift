import SwiftUI
import UIKit

/// 5×5 dot grid. Drag across dots to draw; lifting the finger submits the pattern.
struct PatternGridView: View {
    var isDisabled = false
    var onComplete: (Pattern) -> Void

    @State private var selected: [Int] = []
    @State private var fingerPoint: CGPoint?
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private let n = Pattern.gridSize

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cell = side / CGFloat(n)

            ZStack {
                Path { path in
                    guard let first = selected.first else { return }
                    path.move(to: center(of: first, cell: cell))
                    for dot in selected.dropFirst() { path.addLine(to: center(of: dot, cell: cell)) }
                    if let fingerPoint { path.addLine(to: fingerPoint) }
                }
                .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

                ForEach(0..<(n * n), id: \.self) { dot in
                    let isOn = selected.contains(dot)
                    Circle()
                        .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: cell * (isOn ? 0.3 : 0.2), height: cell * (isOn ? 0.3 : 0.2))
                        .position(center(of: dot, cell: cell))
                        .animation(.spring(duration: 0.15), value: isOn)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isDisabled else { return }
                        if selected.isEmpty { haptics.prepare() }
                        fingerPoint = value.location
                        if let dot = hitDot(at: value.location, cell: cell) { add(dot) }
                    }
                    .onEnded { _ in
                        guard !isDisabled else { return }
                        let pattern = Pattern(dots: selected)
                        fingerPoint = nil
                        selected = []
                        if !pattern.dots.isEmpty { onComplete(pattern) }
                    }
            )
            .opacity(isDisabled ? 0.4 : 1)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Pattern grid, five by five dots")
    }

    private func add(_ dot: Int) {
        guard !selected.contains(dot) else { return }
        if let last = selected.last {
            for between in Pattern.dotsBetween(last, dot) where !selected.contains(between) {
                selected.append(between)
            }
        }
        selected.append(dot)
        haptics.impactOccurred()
    }

    private func center(of dot: Int, cell: CGFloat) -> CGPoint {
        CGPoint(x: (CGFloat(dot % n) + 0.5) * cell, y: (CGFloat(dot / n) + 0.5) * cell)
    }

    /// The dot under the finger, if the finger is within 35% of a cell from its center.
    private func hitDot(at point: CGPoint, cell: CGFloat) -> Int? {
        let col = Int(point.x / cell), row = Int(point.y / cell)
        guard point.x >= 0, point.y >= 0, (0..<n).contains(col), (0..<n).contains(row) else { return nil }
        let dot = row * n + col
        let c = center(of: dot, cell: cell)
        return hypot(point.x - c.x, point.y - c.y) <= cell * 0.35 ? dot : nil
    }
}
