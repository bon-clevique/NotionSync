import Foundation

/// Extracts Notion database IDs from share links and raw input strings.
///
/// Stateless utility — all methods are static.
struct NotionURLParser: Sendable {

    /// Extracts a Notion database ID (UUID) from a share link or raw ID string.
    ///
    /// Accepted inputs:
    /// - A UUID with dashes (e.g. `"12345678-1234-1234-1234-123456789abc"`)
    /// - 32 hex chars without dashes
    /// - A `notion.so` or `notion.site` share URL whose last path component
    ///   contains a 32-char hex database ID
    ///
    /// - Returns: The database ID formatted as a lowercase UUID, or `nil` if
    ///   the input cannot be parsed.
    static func extractDatabaseId(from input: String) -> String? {
        // Already a UUID with dashes
        if input.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return input.lowercased()
        }

        // 32 hex chars without dashes
        if input.range(of: #"^[0-9a-f]{32}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return formatAsUUID(input.lowercased())
        }

        // Notion share URL — extract 32 hex chars from last path component
        guard let url = URL(string: input),
              let host = url.host,
              isNotionHost(host) else {
            return nil
        }
        let lastComponent = url.lastPathComponent
        guard let match = lastComponent.range(
            of: #"[0-9a-f]{32}"#,
            options: [.regularExpression, .caseInsensitive, .backwards]
        ) else {
            return nil
        }
        return formatAsUUID(String(lastComponent[match]).lowercased())
    }

    /// Returns `true` when `host` is a known Notion domain.
    private static func isNotionHost(_ host: String) -> Bool {
        host == "notion.so"
            || host.hasSuffix(".notion.so")
            || host == "notion.site"
            || host.hasSuffix(".notion.site")
    }

    /// Formats a 32-character hex string as a UUID (8-4-4-4-12).
    static func formatAsUUID(_ hex: String) -> String {
        let h = Array(hex)
        return [
            String(h[0..<8]),
            String(h[8..<12]),
            String(h[12..<16]),
            String(h[16..<20]),
            String(h[20..<32]),
        ].joined(separator: "-")
    }
}
