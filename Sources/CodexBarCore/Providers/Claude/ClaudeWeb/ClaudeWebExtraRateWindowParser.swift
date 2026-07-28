import Foundation

enum ClaudeWebExtraRateWindowParser {
    private static let definitions: [(id: String, title: String, keys: [String])] = [
        (
            id: "claude-routines",
            title: "Daily Routines",
            keys: [
                "seven_day_routines",
                "seven_day_claude_routines",
                "claude_routines",
                "routines",
                "routine",
                "seven_day_cowork",
                "cowork",
            ]),
    ]

    static func parse(from json: [String: Any]) -> (windows: [NamedRateWindow], sourceKeys: [String: String]) {
        var windows: [NamedRateWindow] = []
        var sourceKeys: [String: String] = [:]
        windows.reserveCapacity(Self.definitions.count)

        for definition in Self.definitions {
            guard let foundWindow = Self.firstUsageWindow(in: json, keys: definition.keys) else { continue }
            let rawWindow = foundWindow.window
            guard let utilization = Self.percentValue(from: rawWindow["utilization"]) else { continue }
            let resetsAt = (rawWindow["resets_at"] as? String).flatMap(Self.parseISO8601Date)
            windows.append(Self.namedWindow(
                id: definition.id,
                title: definition.title,
                usedPercent: utilization,
                resetsAt: resetsAt))
            sourceKeys[definition.id] = foundWindow.sourceKey
        }
        windows.append(contentsOf: Self.scopedWeeklyLimitWindows(from: json))
        return (windows, sourceKeys)
    }

    private static func scopedWeeklyLimitWindows(from json: [String: Any]) -> [NamedRateWindow] {
        guard let limits = json["limits"] as? [[String: Any]] else { return [] }
        let mappedLimits = limits.map { entry in
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            return ClaudeScopedWeeklyLimitMapper.Limit(
                kind: entry["kind"] as? String,
                group: entry["group"] as? String,
                percent: Self.percentValue(from: entry["percent"]),
                resetsAt: (entry["resets_at"] as? String).flatMap(Self.parseISO8601Date),
                modelID: model?["id"] as? String,
                modelName: model?["display_name"] as? String)
        }
        return ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: mappedLimits)
    }

    private static func namedWindow(
        id: String,
        title: String,
        usedPercent: Double,
        resetsAt: Date?) -> NamedRateWindow
    {
        NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: resetsAt,
                resetDescription: nil))
    }

    private static func firstUsageWindow(
        in json: [String: Any],
        keys: [String]) -> (window: [String: Any], sourceKey: String)?
    {
        for key in keys {
            if let window = json[key] as? [String: Any] {
                return (window, key)
            }
        }
        return nil
    }

    private static func percentValue(from value: Any?) -> Double? {
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        return nil
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
