//
//  diff.swift
//  diffs
//

import Foundation

enum DiffOperation {
    case equal
    case insert
    case delete
}

struct DiffLine: Equatable {
    let operation: DiffOperation
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct DiffHunk: Equatable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffLine]
}

struct InlineDiffRange: Equatable {
    let start: Int
    let length: Int
}

struct InlineDiffResult: Equatable {
    let oldRemoved: [InlineDiffRange]
    let newAdded: [InlineDiffRange]
}

enum CodeDiff {
    // MARK: - Public API

    static func computeLines(old: [String], new: [String]) -> [DiffLine] {
        let (trace, maxSteps) = myersDiff(old: old, new: new)
        let backtracked = backtrack(old: old, new: new, trace: trace, maxSteps: maxSteps)

        var result: [DiffLine] = []
        var oldLineNum = 1
        var newLineNum = 1

        for (op, text) in backtracked {
            switch op {
            case .equal:
                result.append(DiffLine(
                    operation: .equal,
                    text: text,
                    oldLineNumber: oldLineNum,
                    newLineNumber: newLineNum
                ))
                oldLineNum += 1
                newLineNum += 1
            case .delete:
                result.append(DiffLine(
                    operation: .delete,
                    text: text,
                    oldLineNumber: oldLineNum,
                    newLineNumber: nil
                ))
                oldLineNum += 1
            case .insert:
                result.append(DiffLine(
                    operation: .insert,
                    text: text,
                    oldLineNumber: nil,
                    newLineNumber: newLineNum
                ))
                newLineNum += 1
            }
        }

        return result
    }

    static func computeUnified(old: [String], new: [String], context: Int = 3) -> [DiffHunk] {
        let diffLines = computeLines(old: old, new: new)
        return makeHunks(diffLines: diffLines, context: context)
    }

    /// Character-level diff for two corresponding changed lines.
    static func computeInline(oldLine: String, newLine: String) -> InlineDiffResult {
        let oldChars = Array(oldLine)
        let newChars = Array(newLine)
        let (trace, maxSteps) = myersDiff(old: oldChars, new: newChars)
        let steps = backtrack(old: oldChars, new: newChars, trace: trace, maxSteps: maxSteps)

        var oldRemoved: [InlineDiffRange] = []
        var newAdded: [InlineDiffRange] = []

        var oldOffset = 0
        var newOffset = 0

        for (op, _) in steps {
            switch op {
            case .equal:
                oldOffset += 1
                newOffset += 1
            case .delete:
                if let last = oldRemoved.last, last.start + last.length == oldOffset {
                    oldRemoved[oldRemoved.count - 1] = InlineDiffRange(start: last.start, length: last.length + 1)
                } else {
                    oldRemoved.append(InlineDiffRange(start: oldOffset, length: 1))
                }
                oldOffset += 1
            case .insert:
                if let last = newAdded.last, last.start + last.length == newOffset {
                    newAdded[newAdded.count - 1] = InlineDiffRange(start: last.start, length: last.length + 1)
                } else {
                    newAdded.append(InlineDiffRange(start: newOffset, length: 1))
                }
                newOffset += 1
            }
        }

        return InlineDiffResult(oldRemoved: oldRemoved, newAdded: newAdded)
    }

    // MARK: - Myers Diff Algorithm

    private static func myersDiff<T: Equatable>(old: [T], new: [T]) -> ([[Int: Int]], Int) {
        let n = old.count
        let m = new.count
        let maxSteps = n + m
        var trace: [[Int: Int]] = []
        var v: [Int: Int] = [1: 0]

        for d in 0...maxSteps {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                let vkMinus = v[k - 1] ?? -1
                let vkPlus = v[k + 1] ?? -1
                if k == -d || (k != d && vkMinus < vkPlus) {
                    x = vkPlus
                } else {
                    x = vkMinus + 1
                }
                var y = x - k
                while x < n && y < m && old[x] == new[y] {
                    x += 1
                    y += 1
                }
                v[k] = x
                if x >= n && y >= m {
                    return (trace, d)
                }
            }
        }
        return (trace, maxSteps)
    }

    private static func backtrack<T: Equatable>(old: [T], new: [T], trace: [[Int: Int]], maxSteps: Int) -> [(operation: DiffOperation, value: T)] {
        var steps: [(operation: DiffOperation, value: T)] = []
        var x = old.count
        var y = new.count
        var k = x - y

        for d in (0...maxSteps).reversed() {
            guard d < trace.count else { continue }
            let v = trace[d]
            let vkMinus = v[k - 1] ?? -1
            let vkPlus = v[k + 1] ?? -1
            let prevK: Int
            if k == -d || (k != d && vkMinus < vkPlus) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[prevK] ?? max(x - 1, 0)
            let prevY = prevX - prevK

            while x > prevX && y > prevY {
                x -= 1
                y -= 1
                steps.append((.equal, old[x]))
            }

            if x == prevX {
                if y > 0 {
                    y -= 1
                    steps.append((.insert, new[y]))
                }
            } else if y == prevY {
                if x > 0 {
                    x -= 1
                    steps.append((.delete, old[x]))
                }
            }

            k = prevK
        }

        return steps.reversed()
    }

    // MARK: - Hunk Construction

    private static func makeHunks(diffLines: [DiffLine], context: Int) -> [DiffHunk] {
        guard !diffLines.isEmpty else { return [] }

        let changeIndices = diffLines.enumerated().compactMap { index, line -> Int? in
            line.operation == .equal ? nil : index
        }

        guard !changeIndices.isEmpty else {
            let count = diffLines.count
            return [DiffHunk(
                oldStart: 1,
                oldCount: count,
                newStart: 1,
                newCount: count,
                lines: diffLines
            )]
        }

        var groups: [ClosedRange<Int>] = []
        for idx in changeIndices {
            let start = max(0, idx - context)
            let end = min(diffLines.count - 1, idx + context)
            if let last = groups.last, last.upperBound + 1 >= start {
                groups[groups.count - 1] = last.lowerBound...end
            } else {
                groups.append(start...end)
            }
        }

        return groups.map { range in
            let hunkLines = Array(diffLines[range])
            let oldStart = hunkLines.first?.oldLineNumber ?? 1
            let newStart = hunkLines.first?.newLineNumber ?? 1
            let oldCount = hunkLines.filter { $0.oldLineNumber != nil }.count
            let newCount = hunkLines.filter { $0.newLineNumber != nil }.count
            return DiffHunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: hunkLines
            )
        }
    }
}
