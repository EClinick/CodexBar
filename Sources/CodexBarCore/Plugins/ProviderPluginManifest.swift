#if canImport(JavaScriptCore)
import Foundation
@preconcurrency import JavaScriptCore

public struct ProviderPluginSetting: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case plain
        case secure
    }

    public let key: String
    public let title: String
    public let subtitle: String?
    public let kind: Kind

    public init(key: String, title: String, subtitle: String? = nil, kind: Kind = .secure) {
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

public struct ProviderPluginAuth: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case bearer
        case xAPIKey = "x-api-key"
        case header
    }

    public let type: Kind
    public let header: String
    public let secret: String

    public init(type: Kind, header: String, secret: String) {
        self.type = type
        self.header = header
        self.secret = secret
    }
}

public struct ProviderPluginManifest: @unchecked Sendable {
    public let id: UsageProvider
    public let name: String
    public let endpoints: Set<String>
    public let auth: ProviderPluginAuth
    public let settings: [ProviderPluginSetting]

    let fetchUsage: JSValue

    init(definition: JSValue) throws {
        guard definition.isObject else {
            throw ProviderPluginError.invalidManifest("defineProvider(...) requires an object")
        }

        let rawID = try Self.requiredString(definition, property: "id")
        guard let id = UsageProvider(rawValue: rawID) else {
            throw ProviderPluginError.invalidManifest(
                "provider id '\(rawID)' must match an existing UsageProvider raw value")
        }
        self.id = id
        self.name = try Self.boundedString(definition, property: "name", maximumLength: 80)

        let endpointValue = definition.forProperty("endpoints")
        guard let endpointValue, endpointValue.isArray else {
            throw ProviderPluginError.invalidManifest("'endpoints' must be a non-empty array of HTTPS origins")
        }
        let endpointCount = Int(endpointValue.forProperty("length")?.toInt32() ?? 0)
        guard endpointCount > 0 else {
            throw ProviderPluginError.invalidManifest("'endpoints' must not be empty")
        }
        var endpoints: Set<String> = []
        for index in 0..<endpointCount {
            guard let rawEndpoint = endpointValue.atIndex(index), rawEndpoint.isString else {
                throw ProviderPluginError.invalidManifest("endpoint at index \(index) must be a string")
            }
            try endpoints.insert(ProviderPluginOrigin.normalizedOrigin(rawEndpoint.toString()))
        }
        self.endpoints = endpoints

        guard let authValue = definition.forProperty("auth"), authValue.isObject else {
            throw ProviderPluginError.invalidManifest("'auth' must be an object")
        }
        let rawAuthType = try Self.requiredString(authValue, property: "type")
        guard let authType = ProviderPluginAuth.Kind(rawValue: rawAuthType) else {
            throw ProviderPluginError.invalidManifest("unsupported auth type '\(rawAuthType)'")
        }
        let secret = try Self.requiredString(authValue, property: "secret")
        let header: String = switch authType {
        case .bearer:
            "Authorization"
        case .xAPIKey:
            "X-API-Key"
        case .header:
            try Self.requiredString(authValue, property: "header")
        }
        guard Self.isValidHeaderName(header) else {
            throw ProviderPluginError.invalidManifest("auth header '\(header)' is invalid")
        }
        self.auth = ProviderPluginAuth(type: authType, header: header, secret: secret)

        guard let settingsValue = definition.forProperty("settings"), settingsValue.isArray else {
            throw ProviderPluginError.invalidManifest("'settings' must be an array")
        }
        let settingCount = Int(settingsValue.forProperty("length")?.toInt32() ?? 0)
        var settings: [ProviderPluginSetting] = []
        var settingKeys: Set<String> = []
        for index in 0..<settingCount {
            guard let setting = settingsValue.atIndex(index), setting.isObject else {
                throw ProviderPluginError.invalidManifest("setting at index \(index) must be an object")
            }
            let key = try Self.requiredString(setting, property: "key")
            guard settingKeys.insert(key).inserted else {
                throw ProviderPluginError.invalidManifest("duplicate setting key '\(key)'")
            }
            let title = try Self.boundedString(setting, property: "title", maximumLength: 80)
            let subtitle = try Self.optionalBoundedString(setting, property: "subtitle", maximumLength: 256)
            let rawKind = try Self.optionalString(setting, property: "type") ?? "secure"
            guard let kind = ProviderPluginSetting.Kind(rawValue: rawKind) else {
                throw ProviderPluginError.invalidManifest("unsupported setting type '\(rawKind)'")
            }
            settings.append(ProviderPluginSetting(key: key, title: title, subtitle: subtitle, kind: kind))
        }
        guard settingKeys.contains(secret) else {
            throw ProviderPluginError.invalidManifest("auth secret '\(secret)' must be declared in settings")
        }
        self.settings = settings

        guard let fetchUsage = definition.forProperty("fetchUsage"), fetchUsage.isObject else {
            throw ProviderPluginError.invalidManifest("'fetchUsage' must be a function")
        }
        self.fetchUsage = fetchUsage
    }

    private static func requiredString(_ object: JSValue, property: String) throws -> String {
        guard let value = object.forProperty(property), value.isString else {
            throw ProviderPluginError.invalidManifest("'\(property)' must be a string")
        }
        let string = value.toString().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else {
            throw ProviderPluginError.invalidManifest("'\(property)' must not be empty")
        }
        return string
    }

    private static func optionalString(_ object: JSValue, property: String) throws -> String? {
        guard let value = object.forProperty(property), !value.isUndefined, !value.isNull else { return nil }
        guard value.isString else {
            throw ProviderPluginError.invalidManifest("'\(property)' must be a string when present")
        }
        return value.toString()
    }

    private static func boundedString(_ object: JSValue, property: String, maximumLength: Int) throws -> String {
        let value = try Self.requiredString(object, property: property)
        guard value.utf8.count <= maximumLength else {
            throw ProviderPluginError.invalidManifest("'\(property)' exceeds \(maximumLength) UTF-8 bytes")
        }
        return value
    }

    private static func optionalBoundedString(
        _ object: JSValue,
        property: String,
        maximumLength: Int) throws -> String?
    {
        guard let raw = try optionalString(object, property: property) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maximumLength else {
            throw ProviderPluginError.invalidManifest("'\(property)' exceeds \(maximumLength) UTF-8 bytes")
        }
        return value.isEmpty ? nil : value
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
        }
    }
}

enum ProviderPluginOrigin {
    static func normalizedOrigin(_ rawValue: String) throws -> String {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw ProviderPluginError.invalidManifest("endpoint '\(rawValue)' must be an HTTPS origin")
        }
        let port = components.port
        return "https://\(host)\(port == nil || port == 443 ? "" : ":\(port!)")"
    }

    static func normalizedOrigin(of url: URL) throws -> String {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            throw ProviderPluginError.networkPolicy("only HTTPS URLs without user info are allowed")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw ProviderPluginError.networkPolicy("request URL has no host")
        }
        let port = url.port
        return "https://\(host)\(port == nil || port == 443 ? "" : ":\(port!)")"
    }
}

public enum ProviderPluginError: LocalizedError, Sendable, Equatable {
    case load(String)
    case invalidManifest(String)
    case networkPolicy(String)
    case http(String)
    case secretAccess(String)
    case invalidSnapshot(String)
    case script(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .load(message): "Provider plugin load failed: \(message)"
        case let .invalidManifest(message): "Invalid provider plugin manifest: \(message)"
        case let .networkPolicy(message): "Provider plugin network policy rejected the request: \(message)"
        case let .http(message): "Provider plugin HTTP error: \(message)"
        case let .secretAccess(message): "Provider plugin secret access denied: \(message)"
        case let .invalidSnapshot(message): "Invalid provider plugin snapshot: \(message)"
        case let .script(message): "Provider plugin script failed: \(message)"
        case .timedOut: "Provider plugin timed out"
        }
    }
}
#endif
