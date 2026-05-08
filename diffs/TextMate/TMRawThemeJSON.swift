// Decodes VS Code theme JSON (`theme-vesper.json`) into `IRawTheme` for `Theme.createFromRawTheme`.

import Foundation

private struct RawThemeJSON: Decodable {
    var name: String?
    var tokenColors: [RawThemeSettingJSON]
}

private struct RawThemeSettingJSON: Decodable {
    var name: String?
    var scope: ScopeJSON?
    /// Some themes (e.g. Vesper) include `tokenColors` rows with only `scope` and no `settings`.
    var settings: RawThemeStyleJSON?
}

private enum ScopeJSON: Decodable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? c.decode([String].self) {
            self = .array(a)
            return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "scope must be string or array"))
    }
}

private struct RawThemeStyleJSON: Decodable {
    var foreground: String?
    var background: String?
    var fontStyle: String?

    static let empty = RawThemeStyleJSON(foreground: nil, background: nil, fontStyle: nil)
}

private final class BridgedThemeSetting: IRawThemeSetting {
    let name: String?
    let scope: ThemeScopeField?
    let themeSettings: TMRawThemeStyleValues

    init(name: String?, scope: ThemeScopeField?, themeSettings: TMRawThemeStyleValues) {
        self.name = name
        self.scope = scope
        self.themeSettings = themeSettings
    }
}

private struct BridgedStyleBag: TMRawThemeStyleValues {
    let fontStyle: String?
    let foregroundHex: String?
    let backgroundHex: String?
    let fontFamily: String?
    let fontSize: Double?
    let lineHeight: Double?

    init(_ json: RawThemeStyleJSON) {
        fontStyle = json.fontStyle
        foregroundHex = json.foreground
        backgroundHex = json.background
        fontFamily = nil
        fontSize = nil
        lineHeight = nil
    }
}

private final class BridgedRawTheme: IRawTheme {
    let name: String?
    let settings: [IRawThemeSetting]

    init(name: String?, settings: [IRawThemeSetting]) {
        self.name = name
        self.settings = settings
    }
}

/// Decode `Data` from a VS Code theme plist-json export into `IRawTheme`.
public func tmDecodeRawThemeJSON(data: Data) throws -> IRawTheme {
    let decoded = try JSONDecoder().decode(RawThemeJSON.self, from: data)
    let mapped: [IRawThemeSetting] = decoded.tokenColors.map { row in
        let scopeField: ThemeScopeField? = row.scope.map { sj in
            switch sj {
            case .string(let s): return .string(s)
            case .array(let a): return .array(a)
            }
        }
        return BridgedThemeSetting(
            name: row.name,
            scope: scopeField,
            themeSettings: BridgedStyleBag(row.settings ?? .empty)
        )
    }
    return BridgedRawTheme(name: decoded.name, settings: mapped)
}
