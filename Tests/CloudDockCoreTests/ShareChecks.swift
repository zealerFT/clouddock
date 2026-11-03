import Foundation
import CoreImage
import Security
import CryptoKit
import CloudDockCore

final class ShareChecks {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let signed = "https://storage.example/bucket/%E4%B8%AD%E6%96%87%20%26%2B.txt?X-Amz-Date=20231114T221320Z&X-Amz-Expires=5400&X-Amz-Credential=fixture%2F20231114%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Signature=abc%2Bdef&X-Amz-Security-Token=one%2Ftwo%2Bthree%3D"

    func testExpiryBoundariesAndSignedURLPreservation() throws {
        expectEqual(try SharePolicy.duration(amount: 1, unit: .minutes), 60)
        expectEqual(try SharePolicy.duration(amount: 90, unit: .minutes), 5400)
        expectEqual(try SharePolicy.duration(amount: 168, unit: .hours), 604800)
        expectEqual(try SharePolicy.duration(amount: 7, unit: .days), 604800)
        expectThrows(try SharePolicy.duration(amount: 0, unit: .minutes))
        expectThrows(try SharePolicy.duration(amount: -1, unit: .hours))
        expectThrows(try SharePolicy.duration(amount: 169, unit: .hours))
        expectThrows(try SharePolicy.duration(amount: Int.max, unit: .days))
        let share = try DownloadShare(address: signed, now: now)
        expectEqual(share.address, signed)
        expectEqual(share.expiresAt, now.addingTimeInterval(5400))
        let v2 = try DownloadShare(address: "https://storage.example/file?Expires=1700003600&Signature=fixture%2Btoken", now: now)
        expectEqual(v2.expiresAt, now.addingTimeInterval(3600))
        let oss = try DownloadShare(address: "https://storage.example/file?x-oss-date=20231114T221320Z&x-oss-expires=900&x-oss-signature=fixture", now: now)
        expectEqual(oss.expiresAt, now.addingTimeInterval(900))
        let goog = "https://storage.googleapis.com/fixture/file?X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Credential=fixture&X-Goog-Date=20231114T221320Z&X-Goog-Expires=900&X-Goog-SignedHeaders=host&X-Goog-Signature=abc"
        expectEqual(try DownloadShare(address: goog, now: now).expiresAt, now.addingTimeInterval(900))
        for invalid in [goog + "&X-Goog-Expires=900", goog.replacingOccurrences(of: "Expires=900", with: "Expires=604801"),
                        goog.replacingOccurrences(of: "Signature=abc", with: "Signature="),
                        goog.replacingOccurrences(of: "Credential=fixture", with: "Credential="),
                        goog.replacingOccurrences(of: "GOOG4-RSA-SHA256", with: "invalid"),
                        goog.replacingOccurrences(of: "Date=20231114T221320Z", with: "Date=invalid")] {
            expectThrows(try DownloadShare(address: invalid, now: now))
        }
        expectThrows(try DownloadShare(address: goog, now: now.addingTimeInterval(901)))
        expectThrows(try DownloadShare(address: signed, now: now.addingTimeInterval(5401)))
        expectThrows(try DownloadShare(address: "https://storage.example/public-file", now: now))
        expectThrows(try DownloadShare(address: "https://storage.example/file?Expires=1700003600", now: now))
        expectThrows(try DownloadShare(address: signed.replacingOccurrences(of: "5400", with: "604801"), now: now))
        expectThrows(try DownloadShare(address: signed.replacingOccurrences(of: "20231114T221320Z", with: "invalid"), now: now))
        expectThrows(try DownloadShare(address: signed + "&X-Amz-Expires=3600", now: now))
    }

    func testGoogleSignedDownloadAndLocalDirectLink() async throws {
        let privateKey = try required(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try required(SecKeyCopyPublicKey(privateKey))
        let rsa = try required(SecKeyCopyExternalRepresentation(privateKey, nil) as Data?)
        func der(_ tag: UInt8, _ data: Data) -> Data {
            let count = data.count
            let length = count < 128 ? Data([UInt8(count)]) : Data([0x82, UInt8(count >> 8), UInt8(count & 255)])
            return Data([tag]) + length + data
        }
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let pkcs8 = der(0x30, Data([0x02, 0x01, 0x00]) + algorithm + der(0x04, rsa))
        let pem = "-----BEGIN PRIVATE KEY-----\n" + pkcs8.base64EncodedString() + "\n-----END PRIVATE KEY-----"
        let account = try JSONSerialization.data(withJSONObject: ["type": "service_account", "client_email": "fixture@example.invalid", "private_key": pem])
        let secret = Credentials(serviceAccountJSON: String(decoding: account, as: UTF8.self))
        let connection = Connection(name: "GCS signing fixture", provider: .google)
        // Signing must be local and must not fall back to rclone's unsupported link command.
        let engine = StorageEngine(executable: URL(fileURLWithPath: "/nonexistent-rclone"))
        let key = "目录/空 格+%2F&?.txt"
        let path = "/fixture/%E7%9B%AE%E5%BD%95/%E7%A9%BA%20%E6%A0%BC%2B%252F%26%3F.txt"
        var addresses: [String] = []
        for seconds in [60, 900, 604800] {
            let share = try await engine.shareDownload(connection: connection, credentials: secret, bucket: "fixture", key: key, validFor: seconds, now: now)
            let parts = try required(URLComponents(string: share.address))
            expectEqual(parts.host, "storage.googleapis.com")
            expectEqual(parts.percentEncodedPath, path)
            expectEqual(share.expiresAt, now.addingTimeInterval(TimeInterval(seconds)))
            // Fixed canonical resource/query, following Google's V4 specification;
            // verify with the independent public key, including tamper rejection.
            let query = "X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Credential=fixture%40example.invalid%2F20231114%2Fauto%2Fstorage%2Fgoog4_request&X-Goog-Date=20231114T221320Z&X-Goog-Expires=\(seconds)&X-Goog-SignedHeaders=host"
            let canonical = "GET\n\(path)\n\(query)\nhost:storage.googleapis.com\n\nhost\nUNSIGNED-PAYLOAD"
            let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            let signing = Data("GOOG4-RSA-SHA256\n20231114T221320Z\n20231114/auto/storage/goog4_request\n\(digest)".utf8)
            let hex = try required(parts.queryItems?.first { $0.name == "X-Goog-Signature" }?.value)
            expectEqual(hex.count, 512)
            let bytes = Array(hex)
            let signature = try Data(stride(from: 0, to: bytes.count, by: 2).map { try required(UInt8(String(bytes[$0...($0 + 1)]), radix: 16)) })
            expectTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signing as CFData, signature as CFData, nil))
            expectFalse(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, (signing + Data("tampered".utf8)) as CFData, signature as CFData, nil))
            expectEqual(parts.percentEncodedQuery, query + "&X-Goog-Signature=" + hex)
            addresses.append(share.address)
        }
        do {
            _ = try await engine.shareDownload(connection: connection, credentials: Credentials(), bucket: "fixture", key: key, validFor: 900)
            fail("Hosted GCS must require a signing key")
        } catch {}
        let local = Connection(name: "Local GCS", provider: .google, endpoint: "http://localhost:4443")
        let share = try await engine.shareDownload(connection: local, credentials: Credentials(), bucket: "fixture", key: key, validFor: 900)
        expectNil(share.expiresAt)
        expectEqual(share.address, "http://localhost:4443/download/storage/v1/b/fixture/o/%E7%9B%AE%E5%BD%95%2F%E7%A9%BA%20%E6%A0%BC%2B%252F%26%3F.txt?alt=media")
        addresses.append(share.address)
        let detector = try required(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for address in addresses {
            let image = try required(CIImage(data: ShareQRCode.png(address: address)))
            let codes = detector.features(in: image).compactMap { $0 as? CIQRCodeFeature }
            expectEqual(codes.count, 1); expectEqual(codes.first?.messageString, address)
        }
    }

    func testQRCodeDecodesToExactSignedAddress() throws {
        let detector = try required(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for address in [signed, signed + String(repeating: "fixture-token%2Fsegment%2B", count: 24)] {
            let png = try ShareQRCode.png(address: address)
            let image = try required(CIImage(data: png))
            let features = detector.features(in: image).compactMap { $0 as? CIQRCodeFeature }
            expectEqual(features.count, 1)
            expectEqual(features.first?.messageString, address)
            expectTrue(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        }
        expectThrows(try ShareQRCode.png(address: String(repeating: "x", count: 5000)))
    }
}
