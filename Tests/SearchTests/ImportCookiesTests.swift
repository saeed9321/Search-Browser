import XCTest
import Foundation
import CommonCrypto
import CryptoKit
import WebKit
import SQLite3
@testable import Search

final class ImportCookiesTests: XCTestCase {
    func testCookieCollisionIncludesDomainPathAndName() {
        func cookie(_ domain: String, _ path: String, _ name: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: path, .name: name, .value: "value"])!
        }
        let original = CookieImport.identity(cookie("example.com", "/", "session"))
        XCTAssertEqual(original, CookieImport.identity(cookie(".example.com", "/", "session")))
        XCTAssertNotEqual(original, CookieImport.identity(cookie("other.com", "/", "session")))
        XCTAssertNotEqual(original, CookieImport.identity(cookie("example.com", "/account", "session")))
        XCTAssertNotEqual(original, CookieImport.identity(cookie("example.com", "/", "other")))
    }

    private func encrypt(_ plain: Data, key: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: plain.count + 16)
        var size = 0
        let status = plain.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding), key, key.count,
                    [UInt8](repeating: 32, count: 16), bytes.baseAddress, plain.count,
                    &out, out.count, &size)
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + Data(out.prefix(size))
    }

    func testDomainBindingIsVerifiedAndRemovedIncludingEmptyValues() {
        let key = Chromium.stretch("test passphrase")
        let domain = ".example.com"
        let hash = Data(SHA256.hash(data: Data(domain.utf8)))
        let encrypted = encrypt(hash + Data("session-value".utf8), key: key)
        XCTAssertEqual(Chromium.cookieValue(encrypted, key: key, domain: domain, version: 24), "session-value")
        XCTAssertNil(Chromium.cookieValue(encrypted, key: key, domain: ".other.com", version: 24))
        XCTAssertEqual(Chromium.cookieValue(encrypt(hash, key: key), key: key, domain: domain, version: 24), "")
        XCTAssertEqual(Chromium.cookieValue(encrypt(Data("old-value".utf8), key: key), key: key, domain: domain, version: 23), "old-value")
        XCTAssertNil(Chromium.cookieValue(Data("v20unsupported".utf8), key: key, domain: domain, version: 24))
    }

    func testDatabaseSkipsExpiredAndPartitionedCookiesAndKeepsAttributes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cookies-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        func execute(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        execute("CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version', '24');")
        execute("CREATE TABLE cookies(host_key TEXT, name TEXT, path TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, has_expires INTEGER, samesite INTEGER, top_frame_site_key TEXT, has_cross_site_ancestor INTEGER);")
        let key = Chromium.stretch("fixture-key")
        let domain = ".example.com"
        let encrypted = encrypt(Data(SHA256.hash(data: Data(domain.utf8))) + Data("secret".utf8), key: key)
        let hex = encrypted.map { String(format: "%02x", $0) }.joined()
        // Chromium stores has_cross_site_ancestor = 1 for unpartitioned cookies.
        execute("INSERT INTO cookies VALUES('.example.com','session','/','',X'\(hex)',0,1,1,0,2,'',1);")
        execute("INSERT INTO cookies VALUES('example.com','expired','/','old',X'',1,0,0,1,1,'',1);")
        execute("INSERT INTO cookies VALUES('example.com','partitioned','/','value',X'',0,1,0,0,0,'https://other.com',0);")
        execute("INSERT INTO cookies VALUES('example.com','plain','/','',X'',14000000000000000,0,0,1,1,'',0);")
        let batch = try Chromium.decodeCookies(in: file, key: key)
        XCTAssertEqual(batch.skipped, 2)
        XCTAssertEqual(batch.cookies.count, 2)
        let session = try XCTUnwrap(batch.cookies.first { $0.name == "session" })
        XCTAssertEqual(session.value, "secret")
        XCTAssertTrue(session.isSecure)
        XCTAssertTrue(session.isHTTPOnly)
        XCTAssertTrue(session.isSessionOnly)
        XCTAssertEqual(session.sameSitePolicy?.rawValue, "strict")
        let plain = try XCTUnwrap(batch.cookies.first { $0.name == "plain" })
        XCTAssertEqual(plain.value, "")
        XCTAssertFalse(plain.isSecure)
        XCTAssertFalse(plain.isHTTPOnly)
        XCTAssertNotNil(plain.expiresDate)
    }

    @MainActor func testExistingSignInIsPreservedAndHttpOnlyCookieIsInstalled() async throws {
        let websites = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(websites) {} }
        let store = websites.httpCookieStore
        func cookie(_ name: String, _ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: name, .value: value,
                                   .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
        }
        await store.setCookie(cookie("session", "existing"))
        guard !(await store.allCookies()).isEmpty else {
            throw XCTSkip("WebKit's cookie service cannot store the fixture in this environment")
        }
        let result = await CookieImport.install(.init(cookies: [cookie("session", "incoming"), cookie("another", "new")]), into: store)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.kept, 1)
        XCTAssertEqual(result.failed, 0)
        let saved = await store.allCookies()
        XCTAssertEqual(saved.first { $0.name == "session" }?.value, "existing")
        XCTAssertEqual(saved.first { $0.name == "another" }?.isHTTPOnly, true)
    }
}
