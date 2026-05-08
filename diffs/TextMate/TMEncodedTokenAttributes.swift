// vscode-textmate `encodedTokenAttributes.ts`

import Foundation

public typealias EncodedTokenAlias = UInt32

public enum StandardTokenType: UInt32 {
    case other = 0
    case comment = 1
    case string = 2
    case regEx = 3
}

public enum OptionalStandardTokenType: Equatable {
    case other, comment, string, regEx, notSet

    func toNumeric() -> UInt32 {
        switch self {
        case .other: return StandardTokenType.other.rawValue
        case .comment: return StandardTokenType.comment.rawValue
        case .string: return StandardTokenType.string.rawValue
        case .regEx: return StandardTokenType.regEx.rawValue
        case .notSet: return 0
        }
    }
}

public enum EncodedTokenDataConsts {
    static let languageIdMask: UInt32 = 0b00000000_00000000_00000000_11111111
    static let tokenTypeMask: UInt32 = 0b00000000_00000000_00000011_00000000
    static let balancedBracketsMask: UInt32 = 0b00000000_00000000_00000100_00000000
    static let fontStyleMask: UInt32 = 0b00000000_00000000_01111000_00000000
    static let foregroundMask: UInt32 = 0b00000000_11111111_10000000_00000000
    static let backgroundMask: UInt32 = 0b11111111_00000000_00000000_00000000

    static let languageIdOffset = 0
    static let tokenTypeOffset = 8
    static let balancedBracketsOffset = 10
    static let fontStyleOffset = 11
    static let foregroundOffset = 15
    static let backgroundOffset = 24
}

public enum EncodedTokenAttributes {
    public static func getLanguageId(_ encoded: UInt32) -> UInt32 {
        (encoded & EncodedTokenDataConsts.languageIdMask) >> EncodedTokenDataConsts.languageIdOffset
    }

    public static func getTokenType(_ encoded: UInt32) -> StandardTokenType {
        StandardTokenType(rawValue: (encoded & EncodedTokenDataConsts.tokenTypeMask)
            >> EncodedTokenDataConsts.tokenTypeOffset) ?? .other
    }

    public static func containsBalancedBrackets(_ encoded: UInt32) -> Bool {
        (encoded & EncodedTokenDataConsts.balancedBracketsMask) != 0
    }

    public static func getFontStyleRaw(_ encoded: UInt32) -> UInt32 {
        (encoded & EncodedTokenDataConsts.fontStyleMask) >> EncodedTokenDataConsts.fontStyleOffset
    }

    public static func getForeground(_ encoded: UInt32) -> UInt32 {
        (encoded & EncodedTokenDataConsts.foregroundMask) >> EncodedTokenDataConsts.foregroundOffset
    }

    public static func getBackground(_ encoded: UInt32) -> UInt32 {
        (encoded & EncodedTokenDataConsts.backgroundMask) >> EncodedTokenDataConsts.backgroundOffset
    }

    /// Update metadata; zeros/`notSet`/nil mean “leave unchanged”.
    public static func set(
        _ encoded: UInt32,
        languageId: UInt32,
        tokenType: OptionalStandardTokenType,
        balanced: Bool?,
        fontStyleRaw: UInt32?,
        foreground: UInt32,
        background: UInt32
    ) -> UInt32 {
        var lang = getLanguageId(encoded)
        var tokBits = ((encoded & EncodedTokenDataConsts.tokenTypeMask) >> EncodedTokenDataConsts.tokenTypeOffset)
        var balBits: UInt32 = containsBalancedBrackets(encoded) ? 1 : 0
        var fontBits = getFontStyleRaw(encoded)
        var fgBits = getForeground(encoded)
        var bgBits = getBackground(encoded)

        if languageId != 0 { lang = languageId & 0xFF }
        if tokenType != .notSet {
            tokBits = tokenType.toNumeric() & 3
        }
        if let balanced {
            balBits = balanced ? 1 : 0
        }
        if let fs = fontStyleRaw {
            fontBits = fs & 0xF
        }
        if foreground != 0 { fgBits = foreground & ((1 << 9) &- 1) }
        if background != 0 { bgBits = background & ((1 << 9) &- 1) }

        return (lang << EncodedTokenDataConsts.languageIdOffset)
            | (tokBits << EncodedTokenDataConsts.tokenTypeOffset)
            | (balBits << EncodedTokenDataConsts.balancedBracketsOffset)
            | (fontBits << EncodedTokenDataConsts.fontStyleOffset)
            | (fgBits << EncodedTokenDataConsts.foregroundOffset)
            | (bgBits << EncodedTokenDataConsts.backgroundOffset)
    }

    public static func set(_ encoded: UInt32, balanced: Bool) -> UInt32 {
        EncodedTokenAttributes.set(encoded, languageId: 0, tokenType: .notSet, balanced: balanced,
                                   fontStyleRaw: nil, foreground: 0, background: 0)
    }
}

public func packedFontBits(_ fs: FontStyle) -> UInt32 {
    if fs == FontStyle.notSet { return UInt32(bitPattern: 0) }
    return UInt32(fs.rawValue & 0xF)
}

public func optional(from standardType: StandardTokenType) -> OptionalStandardTokenType {
    switch standardType {
    case .other: return .other
    case .comment: return .comment
    case .string: return .string
    case .regEx: return .regEx
    }
}

// MARK: - FontAttribute caching

private final class FontAttribCacheEntry {
    var map: [String: FontAttribute] = [:]
    let lock = NSLock()

    func getOrCreate(fontFamily: String?, fontSize: Double?, lineHeight: Double?, factory: () -> FontAttribute) -> FontAttribute {
        let key = "\(fontFamily ?? "∅")|\(fontSize.map { String($0) } ?? "∅")|\(lineHeight.map { String($0) } ?? "∅")"
        lock.lock(); defer { lock.unlock() }
        if let cached = map[key] { return cached }
        let v = factory()
        map[key] = v
        return v
    }
}

private let fontAttribCache = FontAttribCacheEntry()

/// Cached font decoration tuple used by attributed scope stacks (`FontAttribute` TS).
public final class FontAttribute: Sendable {
    public let fontFamily: String?
    public let fontSize: Double?
    public let lineHeight: Double?

    public init(fontFamily: String?, fontSize: Double?, lineHeight: Double?) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    public static func from(fontFamily: String?, fontSize: Double?, lineHeight: Double?) -> FontAttribute {
        FontAttribute(fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
    }

    /// Theme merge parity with TS `FontAttribute.prototype.with`.
    public func with(_ style: StyleAttributes?) -> FontAttribute {
        guard let style else { return self }
        return fontAttribCache.getOrCreate(fontFamily: style.fontFamily.isEmpty ? fontFamily : style.fontFamily,
                                           fontSize: style.fontSize == 0 ? fontSize : style.fontSize,
                                           lineHeight: style.lineHeight == 0 ? lineHeight : style.lineHeight) {
            FontAttribute(
                fontFamily: style.fontFamily.isEmpty ? fontFamily : style.fontFamily,
                fontSize: style.fontSize == 0 ? fontSize : style.fontSize,
                lineHeight: style.lineHeight == 0 ? lineHeight : style.lineHeight
            )
        }
    }
}
