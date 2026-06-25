// MARK: - AppConfig
//
// Reads the Supabase URL and anon key from the app's Info.plist, which are
// injected at build time from Secrets.xcconfig (gitignored). No credentials are
// hardcoded or committed — see ios/README and Secrets.xcconfig.sample.
//
// The anon key is a public client key (RLS enforces access), but it still lives
// in build config rather than source so it isn't committed.

import Foundation

enum AppConfig {

    // MARK: - Constants

    private enum Keys {
        static let supabaseHost = "SUPABASE_HOST"
        static let supabaseAnonKey = "SUPABASE_ANON_KEY"
    }

    // MARK: - Errors

    enum ConfigError: LocalizedError {
        case missing(String)
        case invalidHost(String)

        var errorDescription: String? {
            switch self {
            case .missing(let key):
                return "Missing build configuration value for \(key). "
                    + "Copy Secrets.xcconfig.sample to Secrets.xcconfig and fill it in."
            case .invalidHost(let value):
                return "SUPABASE_HOST is not a valid host: \(value)"
            }
        }
    }

    // MARK: - Values

    /// The Supabase project URL. The config carries only the host (e.g.
    /// `abc123.supabase.co`); the `https://` scheme is added here in Swift so no
    /// slashes need to survive the xcconfig → Info.plist round trip.
    static func supabaseURL() throws -> URL {
        var host = try infoValue(for: Keys.supabaseHost)

        // Tolerate a pasted scheme / trailing slash / path, then keep host only.
        host = host
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)

        var components = URLComponents()
        components.scheme = "https"
        components.host = host

        guard !host.isEmpty, let url = components.url, url.host != nil else {
            throw ConfigError.invalidHost(host)
        }
        return url
    }

    /// The Supabase anon (public) key, from Info.plist (injected via Secrets.xcconfig).
    static func supabaseAnonKey() throws -> String {
        try infoValue(for: Keys.supabaseAnonKey)
    }

    // MARK: - Private Helpers

    private static func infoValue(for key: String) throws -> String {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !raw.contains("YOUR-")            // reject the placeholder from the sample
        else {
            throw ConfigError.missing(key)
        }
        return raw
    }
}
