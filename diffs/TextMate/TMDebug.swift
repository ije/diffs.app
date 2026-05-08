// vscode-textmate `debug.ts`

import Foundation

public enum DebugFlags {
    public nonisolated(unsafe) static var inDebugMode: Bool = {
        ProcessInfo.processInfo.environment["VSCODE_TEXTMATE_DEBUG"].map { !$0.isEmpty } ?? false
    }()
}

/// TS `UseOnigurumaFindOptions` — false matches TS default (anchor resolution via `compileAG`).
public let useOnigurumaFindOptions = false
