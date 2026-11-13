import SwiftUI

/// The lines of a commit graph, one row per commit (in the log's order: children before
/// parents). Each row says where its node sits and which lines cross its top half (from the
/// row above to the node's height) and its bottom half (from there to the row below).
struct CommitGraphRow: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        /// Lanes (columns) the line runs between: `from` at the top of the half, `to` at its bottom.
        let from: Int
        let to: Int
        let color: Int
    }

    let lane: Int
    let color: Int
    let isMerge: Bool
    let top: [Line]
    let bottom: [Line]

    /// Lanes this row draws in.
    var width: Int { ([lane] + (top + bottom).flatMap { [$0.from, $0.to] }).max()! + 1 }
}

enum CommitGraph {
    /// Lays out lanes for commits listed children first. Parents missing from the list (not
    /// loaded yet) keep their lane running to the bottom.
    static func layout(_ commits: [(sha: String, parents: [String])]) -> [CommitGraphRow] {
        var lanes: [String?] = []    // the commit each lane waits for
        var colors: [Int] = []
        var nextColor = 0
        var rows: [CommitGraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane(avoiding: Int? = nil) -> Int {
            if let index = lanes.indices.first(where: { lanes[$0] == nil && $0 != avoiding }) { return index }
            lanes.append(nil)
            colors.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            let before = lanes, beforeColors = colors
            // The node: the first lane waiting for this commit, or a new one (a branch tip).
            let lane: Int
            if let waiting = lanes.firstIndex(of: commit.sha) {
                lane = waiting
            } else {
                lane = freeLane()
                colors[lane] = nextColor
                nextColor += 1
            }
            let color = colors[lane]

            // Top half: lines into the node from every lane waiting for it, others pass by.
            var top: [CommitGraphRow.Line] = []
            for (index, waitingFor) in before.enumerated() where waitingFor != nil {
                top.append(.init(from: index, to: waitingFor == commit.sha ? lane : index, color: beforeColors[index]))
            }
            for index in lanes.indices where lanes[index] == commit.sha { lanes[index] = nil }

            // Bottom half: the node's lane goes on to the first parent; other parents get lines
            // of their own (or join a lane already waiting for them).
            var bottom: [CommitGraphRow.Line] = []
            var fromNode: [Int: Int] = [:]     // lane → color, for lines leaving the node
            var joining: [Int: Int] = [:]      // lane → lane it moves into
            var nodeContinues = false
            if let first = commit.parents.first {
                if let other = lanes.firstIndex(of: first) {
                    if other < lane {
                        fromNode[other] = colors[other]        // this lane ends in the one to its left
                    } else {
                        lanes[lane] = first                    // pull the lane on the right into this one
                        lanes[other] = nil
                        joining[other] = lane
                        nodeContinues = true
                    }
                } else {
                    lanes[lane] = first
                    nodeContinues = true
                }
            }
            for parent in commit.parents.dropFirst() {
                if let other = lanes.firstIndex(of: parent) {
                    fromNode[other] = colors[other]
                } else {
                    let index = freeLane(avoiding: lane)
                    lanes[index] = parent
                    colors[index] = nextColor
                    nextColor += 1
                    fromNode[index] = colors[index]
                }
            }
            for index in lanes.indices {
                if index == lane {
                    if nodeContinues { bottom.append(.init(from: lane, to: lane, color: color)) }
                } else if lanes[index] != nil, before.indices.contains(index), before[index] != nil,
                          before[index] != commit.sha {
                    bottom.append(.init(from: index, to: index, color: colors[index]))  // passing by
                }
            }
            for (index, target) in joining.sorted(by: { $0.key < $1.key }) {
                bottom.append(.init(from: index, to: target, color: beforeColors[index]))
            }
            for (index, lineColor) in fromNode.sorted(by: { $0.key < $1.key }) {
                bottom.append(.init(from: lane, to: index, color: lineColor))
            }
            while lanes.last == .some(nil) {
                lanes.removeLast()
                colors.removeLast()
            }
            rows.append(CommitGraphRow(lane: lane, color: color, isMerge: commit.parents.count > 1,
                                       top: top, bottom: bottom))
        }
        return rows
    }

    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]

    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

/// Draws one commit's piece of the graph. The node sits at `nodeY`; lines below it bend into
/// their lane right away and then run straight down, so a taller row (an expanded commit)
/// just has longer straight lines.
struct CommitGraphCell: View {
    let row: CommitGraphRow
    /// Lanes to make room for (the widest row on screen), and the space between lanes.
    let lanes: Int
    var spacing: CGFloat = 11
    var nodeY: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { spacing * (CGFloat(lane) + 0.5) + 2 }
            let bend = min(spacing, nodeY)
            for line in row.top {
                var path = Path()
                path.move(to: CGPoint(x: x(line.from), y: 0))
                if line.from == line.to {
                    path.addLine(to: CGPoint(x: x(line.from), y: nodeY))
                } else {
                    path.addLine(to: CGPoint(x: x(line.from), y: nodeY - bend))
                    path.addQuadCurve(to: CGPoint(x: x(line.to), y: nodeY), control: CGPoint(x: x(line.from), y: nodeY))
                }
                context.stroke(path, with: .color(CommitGraph.color(line.color)), lineWidth: 1.6)
            }
            for line in row.bottom {
                var path = Path()
                path.move(to: CGPoint(x: x(line.from), y: nodeY))
                if line.from != line.to {
                    path.addQuadCurve(to: CGPoint(x: x(line.to), y: nodeY + bend), control: CGPoint(x: x(line.to), y: nodeY))
                }
                path.addLine(to: CGPoint(x: x(line.to), y: size.height))
                context.stroke(path, with: .color(CommitGraph.color(line.color)), lineWidth: 1.6)
            }
            let node = CGRect(x: x(row.lane) - 4, y: nodeY - 4, width: 8, height: 8)
            let color = CommitGraph.color(row.color)
            if row.isMerge {
                context.fill(Path(ellipseIn: node), with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(Path(ellipseIn: node), with: .color(color), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: node), with: .color(color))
            }
        }
        .frame(width: spacing * CGFloat(max(1, lanes)) + 4)
    }
}
