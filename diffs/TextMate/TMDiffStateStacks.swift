// vscode-textmate `diffStateStacks.ts`

import Foundation

public struct AttributedScopeStackFrame: Sendable {
    public let encodedTokenAttributes: UInt32
    public let scopeNames: [ScopeName]

    public init(encodedTokenAttributes: UInt32, scopeNames: [ScopeName]) {
        self.encodedTokenAttributes = encodedTokenAttributes
        self.scopeNames = scopeNames
    }
}

public struct StateStackFrame: Sendable {
    public let ruleId: Int
    public var enterPos: Int?
    public var anchorPos: Int?
    public let beginRuleCapturedEOL: Bool
    public let endRule: String?
    public let nameScopesList: [AttributedScopeStackFrame]
    public let contentNameScopesList: [AttributedScopeStackFrame]

    public init(
        ruleId: Int,
        enterPos: Int? = nil,
        anchorPos: Int? = nil,
        beginRuleCapturedEOL: Bool,
        endRule: String?,
        nameScopesList: [AttributedScopeStackFrame],
        contentNameScopesList: [AttributedScopeStackFrame]
    ) {
        self.ruleId = ruleId
        self.enterPos = enterPos
        self.anchorPos = anchorPos
        self.beginRuleCapturedEOL = beginRuleCapturedEOL
        self.endRule = endRule
        self.nameScopesList = nameScopesList
        self.contentNameScopesList = contentNameScopesList
    }
}

public struct StackDiff: Sendable {
    public let pops: Int
    public let newFrames: [StateStackFrame]

    public init(pops: Int, newFrames: [StateStackFrame]) {
        self.pops = pops
        self.newFrames = newFrames
    }
}

/// Reference equality walk identical to TS `diffStateStacksRefEq`.
public func diffStateStacksRefEq(_ first: StateStackImpl?, _ second: StateStackImpl?) -> StackDiff {
    var pops = 0
    var newFrames: [StateStackFrame] = []

    var curFirst: StateStackImpl? = first
    var curSecond: StateStackImpl? = second

    while curFirst !== curSecond {
        if curFirst != nil && (curSecond == nil || curFirst!.depth >= curSecond!.depth) {
            pops += 1
            curFirst = curFirst?.parent
        } else {
            newFrames.append(curSecond!.toStateStackFrame())
            curSecond = curSecond?.parent
        }
    }

    return StackDiff(pops: pops, newFrames: newFrames.reversed())
}

public func applyStateStackDiff(stack: StateStackImpl?, diff: StackDiff) -> StateStackImpl? {
    var curStack: StateStackImpl? = stack
    for _ in 0..<diff.pops {
        curStack = curStack?.parent
    }
    var stackOut = curStack
    for frame in diff.newFrames {
        stackOut = StateStackImpl.pushFrame(stackOut, frame: frame)
    }
    return stackOut
}
