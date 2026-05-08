// vscode-textmate `grammar/tokenizeString.ts`

import Foundation

final class LocalStackElement {
    public let scopes: AttributedScopeStack
    public let endPos: Int

    public init(scopes: AttributedScopeStack, endPos: Int) {
        self.scopes = scopes
        self.endPos = endPos
    }
}

struct TokenizeStringResult {
    let stack: StateStackImpl
    let stoppedEarly: Bool
}

enum TMTokenizeString {
    static func run(
        grammar: Grammar,
        lineText: OnigStringProtocol,
        isFirstLine: Bool,
        linePos: Int,
        stack: StateStackImpl,
        lineTokens: LineTokens,
        lineFonts: LineFonts,
        checkWhileConditions: Bool,
        timeLimitMs: Int
    ) throws -> TokenizeStringResult {
        try tokenizeImpl(
            grammar: grammar,
            lineText: lineText,
            isFirstLine: isFirstLine,
            linePos: linePos,
            stack: stack,
            lineTokens: lineTokens,
            lineFonts: lineFonts,
            checkWhileConditions: checkWhileConditions,
            timeLimitMs: timeLimitMs
        )
    }
}

private func tokenizeImpl(
    grammar: Grammar,
    lineText: OnigStringProtocol,
    isFirstLine: Bool,
    linePos: Int,
    stack: StateStackImpl,
    lineTokens: LineTokens,
    lineFonts: LineFonts,
    checkWhileConditions: Bool,
    timeLimitMs: Int
) throws -> TokenizeStringResult {
    let produce: (StateStackImpl, Int) -> Void = { st, end in
        lineTokens.produce(stack: st, endIndex: end)
        lineFonts.produce(stack: st, endIndex: end)
    }

    let lineLength = lineText.content.count
    var STOP = false
    var anchorPosition = -1

    var stackVar = stack
    var linePosVar = linePos
    var isFirstLineVar = isFirstLine

    if checkWhileConditions {
        let wr = try checkWhileConditionsFn(
            grammar: grammar,
            lineText: lineText,
            isFirstLine: isFirstLineVar,
            linePos: linePosVar,
            stack: stackVar,
            lineTokens: lineTokens,
            lineFonts: lineFonts
        )
        stackVar = wr.stack
        linePosVar = wr.linePos
        isFirstLineVar = wr.isFirstLine
        anchorPosition = wr.anchorPosition
    }

    let startTime = CFAbsoluteTimeGetCurrent()

    while !STOP {
        if timeLimitMs != 0 {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            if elapsed > timeLimitMs {
                return TokenizeStringResult(stack: stackVar, stoppedEarly: true)
            }
        }

        let r = try matchRuleOrInjections(
            grammar: grammar,
            lineText: lineText,
            isFirstLine: isFirstLineVar,
            linePos: linePosVar,
            stack: stackVar,
            anchorPosition: anchorPosition
        )

        guard let hit = r else {
            produce(stackVar, lineLength)
            STOP = true
            continue
        }

        let captureIndices = hit.captureIndices
        let matchedSlot = hit.ruleId

        let hasAdvanced = !captureIndices.isEmpty && captureIndices[0].end > linePosVar

        switch matchedSlot {
        case .endMarker:
            let poppedRule = stackVar.getRule(grammar) as! BeginEndRule

            produce(stackVar, captureIndices[0].start)
            stackVar = stackVar.withContentNameScopesList(stackVar.nameScopesList!)
            try handleCaptures(
                grammar: grammar,
                lineText: lineText,
                isFirstLine: isFirstLineVar,
                stack: stackVar,
                lineTokens: lineTokens,
                lineFonts: lineFonts,
                captures: poppedRule.endCaptures,
                captureIndices: captureIndices
            )
            produce(stackVar, captureIndices[0].end)

            let popped = stackVar
            stackVar = stackVar.parent!
            anchorPosition = popped.getAnchorPos()

            if !hasAdvanced && popped.getEnterPos() == linePosVar {
                stackVar = popped
                produce(stackVar, lineLength)
                STOP = true
                continue
            }

        case .rule(let matchedRuleId):
            let ruleAny = grammar.getRule(matchedRuleId)

            produce(stackVar, captureIndices[0].start)

            let beforePush = stackVar

            let scopeName = ruleAny.getName(lineText: lineText.content, captureIndices: captureIndices)
            let nameScopesList = stackVar.contentNameScopesList!.pushAttributed(scopePath: scopeName, grammar: grammar)

            stackVar = stackVar.push(
                ruleId: matchedRuleId,
                enterPos: linePosVar,
                anchorPos: anchorPosition,
                beginRuleCapturedEOL: captureIndices[0].end == lineLength,
                endRule: nil,
                nameScopesList: nameScopesList,
                contentNameScopesList: nameScopesList
            )

            if let pushedRule = ruleAny as? BeginEndRule {
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLineVar,
                    stack: stackVar,
                    lineTokens: lineTokens,
                    lineFonts: lineFonts,
                    captures: pushedRule.beginCaptures,
                    captureIndices: captureIndices
                )
                produce(stackVar, captureIndices[0].end)
                anchorPosition = captureIndices[0].end

                let contentName = pushedRule.getContentName(lineText: lineText.content, captureIndices: captureIndices)
                let contentNameScopesList = nameScopesList.pushAttributed(scopePath: contentName, grammar: grammar)
                stackVar = stackVar.withContentNameScopesList(contentNameScopesList)

                if pushedRule.endHasBackReferences {
                    stackVar = stackVar.withEndRule(
                        pushedRule.getEndWithResolvedBackReferences(lineText: lineText.content, captureIndices: captureIndices)
                    )
                }

                if !hasAdvanced && beforePush.hasSameRule(as: stackVar) {
                    stackVar = stackVar.pop()!
                    produce(stackVar, lineLength)
                    STOP = true
                    continue
                }

            } else if let pushedRule = ruleAny as? BeginWhileRule {
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLineVar,
                    stack: stackVar,
                    lineTokens: lineTokens,
                    lineFonts: lineFonts,
                    captures: pushedRule.beginCaptures,
                    captureIndices: captureIndices
                )
                produce(stackVar, captureIndices[0].end)
                anchorPosition = captureIndices[0].end

                let contentName = pushedRule.getContentName(lineText: lineText.content, captureIndices: captureIndices)
                let contentNameScopesList = nameScopesList.pushAttributed(scopePath: contentName, grammar: grammar)
                stackVar = stackVar.withContentNameScopesList(contentNameScopesList)

                if pushedRule.whileHasBackReferences {
                    stackVar = stackVar.withEndRule(
                        pushedRule.getWhileWithResolvedBackReferences(lineText: lineText.content, captureIndices: captureIndices)
                    )
                }

                if !hasAdvanced && beforePush.hasSameRule(as: stackVar) {
                    stackVar = stackVar.pop()!
                    produce(stackVar, lineLength)
                    STOP = true
                    continue
                }

            } else if let matchingRule = ruleAny as? MatchRule {
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLineVar,
                    stack: stackVar,
                    lineTokens: lineTokens,
                    lineFonts: lineFonts,
                    captures: matchingRule.captures,
                    captureIndices: captureIndices
                )
                produce(stackVar, captureIndices[0].end)

                stackVar = stackVar.pop()!

                if !hasAdvanced {
                    stackVar = stackVar.safePop()
                    produce(stackVar, lineLength)
                    STOP = true
                    continue
                }

            } else {
                preconditionFailure("unexpected rule type \(type(of: ruleAny))")
            }

        case .whileMarker:
            preconditionFailure("unexpected while marker in main scanner")
        }

        if captureIndices[0].end > linePosVar {
            linePosVar = captureIndices[0].end
            isFirstLineVar = false
        }
    }

    return TokenizeStringResult(stack: stackVar, stoppedEarly: false)
}

private struct WhileCheckResult {
    let stack: StateStackImpl
    let linePos: Int
    let anchorPosition: Int
    let isFirstLine: Bool
}

private func checkWhileConditionsFn(
    grammar: Grammar,
    lineText: OnigStringProtocol,
    isFirstLine: Bool,
    linePos: Int,
    stack: StateStackImpl,
    lineTokens: LineTokens,
    lineFonts: LineFonts
) throws -> WhileCheckResult {
    let produce: (StateStackImpl, Int) -> Void = { st, end in
        lineTokens.produce(stack: st, endIndex: end)
        lineFonts.produce(stack: st, endIndex: end)
    }

    var anchorPosition = stack.beginRuleCapturedEOL ? 0 : -1

    struct WhileStackEntry {
        let stack: StateStackImpl
        let rule: BeginWhileRule
    }

    var whileRules: [WhileStackEntry] = []
    var node: StateStackImpl? = stack
    while let n = node {
        let nodeRule = n.getRule(grammar)
        if let bw = nodeRule as? BeginWhileRule {
            whileRules.append(WhileStackEntry(stack: n, rule: bw))
        }
        node = n.pop()
    }

    var stackVar = stack
    var linePosVar = linePos
    var isFirstLineVar = isFirstLine

    while let entry = whileRules.popLast() {
        let whileRule = entry.rule
        let prepared = try prepareRuleWhileSearch(
            rule: whileRule,
            grammar: grammar,
            endRegexSource: entry.stack.endRule,
            allowA: isFirstLineVar,
            allowG: linePos == anchorPosition
        )
        let r = prepared.ruleScanner.findNextMatch(string: lineText, startPosition: linePosVar, options: prepared.findOptions)

        if let r {
            let matchedRuleId = r.ruleId
            guard matchedRuleId == .whileMarker else {
                stackVar = entry.stack.pop()!
                break
            }
            let caps = r.captureIndices
            if let cap0 = caps.first {
                produce(entry.stack, cap0.start)
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLineVar,
                    stack: entry.stack,
                    lineTokens: lineTokens,
                    lineFonts: lineFonts,
                    captures: whileRule.whileCaptures,
                    captureIndices: caps
                )
                produce(entry.stack, cap0.end)
                anchorPosition = cap0.end
                if cap0.end > linePosVar {
                    linePosVar = cap0.end
                    isFirstLineVar = false
                }
            }
        } else {
            stackVar = entry.stack.pop()!
            break
        }
    }

    return WhileCheckResult(stack: stackVar, linePos: linePosVar, anchorPosition: anchorPosition, isFirstLine: isFirstLineVar)
}

private struct MatchResult {
    let captureIndices: [IOnigCaptureIndex]
    let ruleId: PatternRuleSlot
}

private struct MatchInjectionsResult {
    let priorityMatch: Bool
    let captureIndices: [IOnigCaptureIndex]
    let ruleId: PatternRuleSlot
}

private func matchRuleOrInjections(
    grammar: Grammar,
    lineText: OnigStringProtocol,
    isFirstLine: Bool,
    linePos: Int,
    stack: StateStackImpl,
    anchorPosition: Int
) throws -> MatchResult? {
    let matchResult = try matchRule(
        grammar: grammar,
        lineText: lineText,
        isFirstLine: isFirstLine,
        linePos: linePos,
        stack: stack,
        anchorPosition: anchorPosition
    )

    let injections = try grammar.getInjections()
    if injections.isEmpty {
        return matchResult
    }

    guard let injectionResult = try matchInjections(
        injections: injections,
        grammar: grammar,
        lineText: lineText,
        isFirstLine: isFirstLine,
        linePos: linePos,
        stack: stack,
        anchorPosition: anchorPosition
    ) else {
        return matchResult
    }

    guard let matchResult else {
        return MatchResult(captureIndices: injectionResult.captureIndices, ruleId: injectionResult.ruleId)
    }

    let ms = matchResult.captureIndices[0].start
    let ins = injectionResult.captureIndices[0].start

    if ins < ms || (injectionResult.priorityMatch && ins == ms) {
        return MatchResult(captureIndices: injectionResult.captureIndices, ruleId: injectionResult.ruleId)
    }
    return matchResult
}

private func matchRule(
    grammar: Grammar,
    lineText: OnigStringProtocol,
    isFirstLine: Bool,
    linePos: Int,
    stack: StateStackImpl,
    anchorPosition: Int
) throws -> MatchResult? {
    let rule = stack.getRule(grammar)
    let prepared = try prepareRuleSearch(
        rule: rule,
        grammar: grammar,
        endRegexSource: stack.endRule,
        allowA: isFirstLine,
        allowG: linePos == anchorPosition
    )

    guard let r = prepared.ruleScanner.findNextMatch(string: lineText, startPosition: linePos, options: prepared.findOptions) else {
        return nil
    }

    return MatchResult(captureIndices: r.captureIndices, ruleId: r.ruleId)
}

private func matchInjections(
    injections: [Injection],
    grammar: Grammar,
    lineText: OnigStringProtocol,
    isFirstLine: Bool,
    linePos: Int,
    stack: StateStackImpl,
    anchorPosition: Int
) throws -> MatchInjectionsResult? {
    var bestRating = Int.max
    var bestCaps: [IOnigCaptureIndex]?
    var bestRuleId: PatternRuleSlot?
    var bestPriority = 0

    let scopes = stack.contentNameScopesList!.getScopeNames()

    for injection in injections {
        guard injection.matcher(scopes) else { continue }
        guard grammar.hasCompiledRule(injection.ruleId) else { continue }

        let rule = grammar.getRule(injection.ruleId)
        let prepared = try prepareRuleSearch(
            rule: rule,
            grammar: grammar,
            endRegexSource: nil,
            allowA: isFirstLine,
            allowG: linePos == anchorPosition
        )

        guard let matchResult = prepared.ruleScanner.findNextMatch(string: lineText, startPosition: linePos, options: prepared.findOptions) else {
            continue
        }

        let rating = matchResult.captureIndices[0].start
        if rating >= bestRating {
            continue
        }

        bestRating = rating
        bestCaps = matchResult.captureIndices
        bestRuleId = matchResult.ruleId
        bestPriority = injection.priority

        if bestRating == linePos {
            break
        }
    }

    guard let caps = bestCaps, let rid = bestRuleId else { return nil }

    return MatchInjectionsResult(priorityMatch: bestPriority == -1, captureIndices: caps, ruleId: rid)
}

private struct PreparedRuleSearch {
    let ruleScanner: CompiledRule<PatternRuleSlot>
    let findOptions: FindOption
}

private func prepareRuleSearch(
    rule: RuleBase,
    grammar: Grammar,
    endRegexSource: String?,
    allowA: Bool,
    allowG: Bool
) throws -> PreparedRuleSearch {
    if useOnigurumaFindOptions {
        let scanner = try rule.compile(grammar: grammar, endRegexSource: endRegexSource)
        return PreparedRuleSearch(ruleScanner: scanner, findOptions: findFindOptions(allowA: allowA, allowG: allowG))
    }
    let scanner = try rule.compileAG(grammar: grammar, endRegexSource: endRegexSource, allowA: allowA, allowG: allowG)
    return PreparedRuleSearch(ruleScanner: scanner, findOptions: .none)
}

private struct PreparedWhileSearch {
    let ruleScanner: CompiledRule<BeginWhileRule.WhilePatternSlot>
    let findOptions: FindOption
}

private func prepareRuleWhileSearch(
    rule: BeginWhileRule,
    grammar: Grammar,
    endRegexSource: String?,
    allowA: Bool,
    allowG: Bool
) throws -> PreparedWhileSearch {
    if useOnigurumaFindOptions {
        let scanner = try rule.compileWhile(grammar: grammar, endRegexSource: endRegexSource)
        return PreparedWhileSearch(ruleScanner: scanner, findOptions: findFindOptions(allowA: allowA, allowG: allowG))
    }
    let scanner = try rule.compileWhileAG(grammar: grammar, endRegexSource: endRegexSource, allowA: allowA, allowG: allowG)
    return PreparedWhileSearch(ruleScanner: scanner, findOptions: .none)
}

private func findFindOptions(allowA: Bool, allowG: Bool) -> FindOption {
    var o = FindOption.none
    if !allowA { o.insert(.notBeginString) }
    if !allowG { o.insert(.notBeginPosition) }
    return o
}

private func handleCaptures(
    grammar: Grammar,
    lineText: OnigStringProtocol,
    isFirstLine: Bool,
    stack: StateStackImpl,
    lineTokens: LineTokens,
    lineFonts: LineFonts,
    captures: [CaptureRule?],
    captureIndices: [IOnigCaptureIndex]
) throws {
    let produceFromScopes: (AttributedScopeStack?, Int) -> Void = { scopesList, end in
        lineTokens.produceFromScopes(scopesList: scopesList, endIndex: end)
        lineFonts.produceFromScopes(scopesList: scopesList, endIndex: end)
    }
    let produce: (StateStackImpl, Int) -> Void = { st, end in
        lineTokens.produce(stack: st, endIndex: end)
        lineFonts.produce(stack: st, endIndex: end)
    }

    if captures.isEmpty { return }

    let lineTextContent = lineText.content

    let len = min(captures.count, captureIndices.count)
    var localStack: [LocalStackElement] = []
    guard let cap0 = captureIndices.first else { return }
    let maxEnd = cap0.end

    for i in 0..<len {
        guard let captureRule = captures[i] else { continue }
        let captureIndex = captureIndices[i]

        if captureIndex.length == 0 { continue }

        if captureIndex.start > maxEnd { break }

        while let last = localStack.last, last.endPos <= captureIndex.start {
            produceFromScopes(last.scopes, last.endPos)
            localStack.removeLast()
        }

        if let last = localStack.last {
            produceFromScopes(last.scopes, captureIndex.start)
        } else {
            produce(stack, captureIndex.start)
        }

        if let retok = captureRule.retokenizeCapturedWithRuleId {
            guard grammar.hasCompiledRule(retok) else { continue }
            let scopeName = captureRule.getName(lineText: lineTextContent, captureIndices: captureIndices)
            let nameScopesList = stack.contentNameScopesList!.pushAttributed(scopePath: scopeName, grammar: grammar)
            let contentName = captureRule.getContentName(lineText: lineTextContent, captureIndices: captureIndices)
            let contentNameScopesList = nameScopesList.pushAttributed(scopePath: contentName, grammar: grammar)

            let stackClone = stack.push(
                ruleId: retok,
                enterPos: captureIndex.start,
                anchorPos: -1,
                beginRuleCapturedEOL: false,
                endRule: nil,
                nameScopesList: nameScopesList,
                contentNameScopesList: contentNameScopesList
            )

            let sliceEndIdx = lineTextContent.index(lineTextContent.startIndex, offsetBy: captureIndex.end, limitedBy: lineTextContent.endIndex)
                ?? lineTextContent.endIndex
            let slice = String(lineTextContent[..<sliceEndIdx])
            let onigSubStr = grammar.createOnigString(slice)

            _ = try TMTokenizeString.run(
                grammar: grammar,
                lineText: onigSubStr,
                isFirstLine: isFirstLine && captureIndex.start == 0,
                linePos: captureIndex.start,
                stack: stackClone,
                lineTokens: lineTokens,
                lineFonts: lineFonts,
                checkWhileConditions: false,
                timeLimitMs: 0
            )
            continue
        }

        let captureRuleScopeName = captureRule.getName(lineText: lineTextContent, captureIndices: captureIndices)
        if let captureRuleScopeName {
            let base = localStack.last?.scopes ?? stack.contentNameScopesList
            let captureRuleScopesList = base!.pushAttributed(scopePath: captureRuleScopeName, grammar: grammar)
            localStack.append(LocalStackElement(scopes: captureRuleScopesList, endPos: captureIndex.end))
        }
    }

    while let last = localStack.last {
        produceFromScopes(last.scopes, last.endPos)
        localStack.removeLast()
    }
}
