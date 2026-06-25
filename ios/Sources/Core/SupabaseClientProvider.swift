// MARK: - SupabaseClientProvider
//
// Single shared Supabase client for the app. Configures the Postgres date and
// key-coding strategies once, here, so every model uses snake_case ↔ camelCase
// and ISO8601 dates without per-model CodingKeys.
//
// Auth tokens are managed by the Supabase SDK, which persists its session in the
// iOS Keychain by default — credentials are never written to UserDefaults or
// plain files (secure-credential-storage).

import Foundation
import Supabase   // umbrella: provides SupabaseClient, SupabaseClientOptions (+ Auth/PostgREST/Realtime)

/// Provides the app-wide `SupabaseClient`, configured once.
enum SupabaseClientProvider {

    // MARK: - Shared client

    /// The shared client. Throws `AppConfig.ConfigError` if config is missing.
    static func makeClient() throws -> SupabaseClient {
        let url = try AppConfig.supabaseURL()
        let anonKey = try AppConfig.supabaseAnonKey()

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                db: SupabaseClientOptions.DatabaseOptions(
                    encoder: makeEncoder(),
                    decoder: makeDecoder()
                ),
                // Opt into the upcoming initial-session behavior now (silences the
                // SDK's deprecation warning). AuthService checks session.isExpired
                // so a restored-but-expired session still routes to sign-in.
                auth: SupabaseClientOptions.AuthOptions(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    // MARK: - Coding strategies

    /// Decoder matching PostgREST output: snake_case keys, ISO8601 timestamps.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = PostgresDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unparseable timestamp: \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    /// Encoder matching PostgREST input: snake_case keys, ISO8601 timestamps.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - PostgresDate

/// Parses the timestamp/date formats PostgREST returns (timestamptz, date).
enum PostgresDate {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = isoWithFractional.date(from: raw) {
            return date
        }
        if let date = iso.date(from: raw) {
            return date
        }
        return dateOnly.date(from: raw)
    }
}
