import Testing
@testable import Oh_My_Code

struct CommitGraphTests {
    typealias Line = CommitGraphRow.Line

    @Test func linearHistoryIsOneStraightLane() {
        let rows = CommitGraph.layout([("c", ["b"]), ("b", ["a"]), ("a", [])])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows[0].top.isEmpty && rows[0].bottom == [Line(from: 0, to: 0, color: 0)])
        #expect(rows[1].top == [Line(from: 0, to: 0, color: 0)] && rows[1].bottom == [Line(from: 0, to: 0, color: 0)])
        #expect(rows[2].bottom.isEmpty && rows.allSatisfy { !$0.isMerge })
    }

    @Test func branchAndMergeKeepTheMainLineOnTheLeft() {
        // m merges b into a; both come from c.
        let rows = CommitGraph.layout([("m", ["a", "b"]), ("b", ["c"]), ("a", ["c"]), ("c", [])])
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows[0].isMerge && rows[0].bottom == [Line(from: 0, to: 0, color: 0), Line(from: 0, to: 1, color: 1)])
        #expect(rows[1].top == [Line(from: 0, to: 0, color: 0), Line(from: 1, to: 1, color: 1)])
        #expect(rows[1].bottom == [Line(from: 0, to: 0, color: 0), Line(from: 1, to: 1, color: 1)])
        // a's parent c is already awaited on the right: that lane moves into a's.
        #expect(rows[2].bottom == [Line(from: 0, to: 0, color: 0), Line(from: 1, to: 0, color: 1)])
        #expect(rows[3].top == [Line(from: 0, to: 0, color: 0)])
    }

    @Test func twoTipsFromOneCommitJoinOnTheLeft() {
        let rows = CommitGraph.layout([("x", ["p"]), ("y", ["p"]), ("p", [])])
        #expect(rows.map(\.lane) == [0, 1, 0])
        #expect(rows[1].bottom == [Line(from: 0, to: 0, color: 0), Line(from: 1, to: 0, color: 0)])
        #expect(rows[0].color != rows[1].color)
    }

    @Test func parentsNotLoadedYetRunToTheBottom() {
        let rows = CommitGraph.layout([("b", ["a"])])
        #expect(rows[0].bottom == [Line(from: 0, to: 0, color: 0)])
    }

    /// Random histories (branches, merges, several roots): the lines leaving each row are the
    /// lines entering the next, and every parent link is drawn.
    @Test func linesConnectInRandomHistories() {
        var generator = SplitMix(seed: 42)
        for _ in 0..<200 {
            var heads: [String] = []
            var commits: [(sha: String, parents: [String])] = []
            for index in 0..<Int.random(in: 1...40, using: &generator) {
                let sha = "c\(index)"
                var parents: [String] = []
                if !heads.isEmpty, Int.random(in: 0..<10, using: &generator) > 0 {
                    parents.append(heads.randomElement(using: &generator)!)
                    if heads.count > 1, Int.random(in: 0..<4, using: &generator) == 0,
                       let other = heads.filter({ $0 != parents[0] }).randomElement(using: &generator) {
                        parents.append(other)
                        heads.removeAll { $0 == other }
                    }
                }
                if Int.random(in: 0..<3, using: &generator) > 0 { heads.removeAll { $0 == parents.first } }
                heads.append(sha)
                commits.append((sha, parents))
            }
            commits.reverse() // children first, as git lists them
            let rows = CommitGraph.layout(commits)
            let isParent = Set(commits.flatMap(\.parents))
            for (index, row) in rows.enumerated() {
                if index + 1 < rows.count {
                    #expect(Set(row.bottom.map(\.to)) == Set(rows[index + 1].top.map(\.from)), "row \(index)")
                }
                if !commits[index].parents.isEmpty { #expect(row.bottom.contains { $0.from == row.lane }) }
                // A line passing the node's height carries on below it (none just stops).
                for line in row.top where line.to != row.lane {
                    #expect(row.bottom.contains { $0.from == line.to }, "row \(index) drops lane \(line.to)")
                }
                if isParent.contains(commits[index].sha) { #expect(row.top.contains { $0.to == row.lane }) }
            }
        }
    }
}

/// A seeded generator, so the random histories are the same on every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
