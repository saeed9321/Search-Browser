import Foundation
import CommonCrypto
import CryptoKit
import SQLite3
import WebKit

extension Chromium {
    struct CookieBatch {
        var cookies: [HTTPCookie] = []
        var skipped = 0
    }

    static func cookieFile(in profile: URL) -> URL? {
        ["Network/Cookies", "Cookies"].map { profile.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // Cookies at schema version 24 onward contain a SHA-256 domain binding.
    // Verify it before removing it; password decoding cannot be reused here.
    static func cookieValue(_ encrypted: Data, key: [UInt8], domain: String, version: Int) -> String? {
        guard encrypted.prefix(3) == Data("v10".utf8), encrypted.count > 3 else { return nil }
        let body = Array(encrypted.dropFirst(3))
        var output = [UInt8](repeating: 0, count: body.count + 16)
        var size = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                             CCOptions(kCCOptionPKCS7Padding), key, key.count,
                             [UInt8](repeating: 32, count: 16), body, body.count,
                             &output, output.count, &size)
        guard status == kCCSuccess else { return nil }
        var plain = Data(output.prefix(size))
        if version >= 24 {
            guard plain.count >= 32, plain.prefix(32) == Data(SHA256.hash(data: Data(domain.utf8))) else { return nil }
            plain = plain.dropFirst(32)
        }
        return String(data: plain, encoding: .utf8)
    }

    static func decodeCookies(in file: URL, key: [UInt8], now: Date = Date()) throws -> CookieBatch {
        let copy = try Snapshot(of: file)
        defer { withExtendedLifetime(copy) {} }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw Trouble.unreadable
        }
        guard let db = handle else { throw Trouble.unreadable }
        defer { sqlite3_close(db) }
        var meta: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &meta, nil) == SQLITE_OK else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(meta) }
        guard sqlite3_step(meta) == SQLITE_ROW else { throw Trouble.unreadable }
        let version = Int(sqlite3_column_int(meta, 0))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM cookies", -1, &statement, nil) == SQLITE_OK, let rows = statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(rows) }
        var columns: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(rows) {
            columns[String(cString: sqlite3_column_name(rows, index))] = index
        }
        guard ["host_key", "name", "path", "value", "encrypted_value", "expires_utc", "is_secure", "is_httponly", "has_expires"].allSatisfy({ columns[$0] != nil }) else {
            throw Trouble.unreadable
        }
        func string(_ name: String) -> String {
            guard let index = columns[name], let pointer = sqlite3_column_text(rows, index) else { return "" }
            return String(cString: pointer)
        }
        func number(_ name: String) -> Int64 {
            columns[name].map { sqlite3_column_int64(rows, $0) } ?? 0
        }
        var result = CookieBatch()
        var step = sqlite3_step(rows)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(rows) }
            let domain = string("host_key")
            let expiry = Date(timeIntervalSince1970: Double(number("expires_utc")) / 1_000_000 - 11_644_473_600)
            // Partitioned cookies cannot be faithfully represented by HTTPCookie.
            // Only top_frame_site_key marks a partition: Chromium writes has_cross_site_ancestor = 1
            // on every unpartitioned cookie, so that column must not be used as a filter.
            guard string("top_frame_site_key").isEmpty,
                  number("has_expires") == 0 || expiry > now else {
                result.skipped += 1
                continue
            }
            let index = columns["encrypted_value"]!
            let blob = sqlite3_column_blob(rows, index).map {
                Data(bytes: $0, count: Int(sqlite3_column_bytes(rows, index)))
            } ?? Data()
            let value = blob.isEmpty ? string("value") : cookieValue(blob, key: key, domain: domain, version: version)
            guard let value else { result.skipped += 1; continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain, .name: string("name"), .path: string("path"), .value: value,
            ]
            // Foundation treats the presence of these keys as true, even "FALSE".
            if number("is_secure") != 0 { properties[.secure] = "TRUE" }
            if number("is_httponly") != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if number("has_expires") != 0 { properties[.expires] = expiry }
            else { properties[.discard] = "TRUE" }
            if let policy = [0: "none", 1: "lax", 2: "strict"][Int(number("samesite"))], columns["samesite"] != nil {
                properties[.sameSitePolicy] = policy
            }
            guard let cookie = HTTPCookie(properties: properties) else { result.skipped += 1; continue }
            result.cookies.append(cookie)
        }
        guard step == SQLITE_DONE else { throw Trouble.unreadable }
        return result
    }
}

enum CookieImport {
    static func identity(_ cookie: HTTPCookie) -> String {
        let domain = cookie.domain.lowercased().drop(while: { $0 == "." })
        return "\(domain)\u{0}\(cookie.path)\u{0}\(cookie.name)"
    }

    @MainActor static func install(_ batch: Chromium.CookieBatch, into store: WKHTTPCookieStore) async -> (added: Int, kept: Int, failed: Int) {
        let existing = await store.allCookies()
        var seen = Set(existing.map(identity))
        var requested: [HTTPCookie] = []
        var kept = 0
        for cookie in batch.cookies {
            guard seen.insert(identity(cookie)).inserted else { kept += 1; continue }
            await store.setCookie(cookie)
            requested.append(cookie)
        }
        let saved = await store.allCookies()
        let values = Dictionary(saved.map { (identity($0), $0.value) }, uniquingKeysWith: { first, _ in first })
        let added = requested.filter { cookie in
            values[identity(cookie)] == cookie.value
        }.count
        return (added, kept, requested.count - added)
    }
}
