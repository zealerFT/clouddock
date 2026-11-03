import Foundation
import Security

/// Imports a JSON service-account key in memory; no Keychain access is needed.
struct GoogleServiceAccount {
    let email: String
    private let key: SecKey

    init(credentials: Credentials) throws {
        guard let data = credentials.serviceAccountJSON.data(using: .utf8),
              let account = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              account["type"] as? String == "service_account",
              let email = account["client_email"] as? String, !email.isEmpty,
              let pem = account["private_key"] as? String else {
            throw CloudError.message("Google 服务账号 JSON 不完整。")
        }
        let lines = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: lines, options: .ignoreUnknownCharacters) else {
            throw CloudError.message("Google 私钥格式无法解析。")
        }
        let rsa = pem.contains("BEGIN RSA PRIVATE KEY") ? der : try Self.unwrapPKCS8(der)
        guard let key = SecKeyCreateWithData(rsa as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil) else {
            throw CloudError.message("Google 服务账号私钥无法签名，请检查 JSON 密钥文件。")
        }
        self.email = email; self.key = key
    }

    func sign(_ data: Data) throws -> Data {
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil) as Data? else {
            throw CloudError.message("Google 服务账号私钥无法签名，请检查 JSON 密钥文件。")
        }
        return signature
    }

    private static func unwrapPKCS8(_ data: Data) throws -> Data {
        let bytes = Array(data)
        func value(_ index: inout Int, tag: UInt8) throws -> Range<Int> {
            guard index + 2 <= bytes.count, bytes[index] == tag else { throw CloudError.message("Google 私钥格式无效。") }
            index += 1; var length = Int(bytes[index]); index += 1
            if length & 128 != 0 {
                let count = length & 127
                guard (1...4).contains(count), index + count <= bytes.count else { throw CloudError.message("Google 私钥长度无效。") }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[index]); index += 1 }
            }
            guard length <= bytes.count - index else { throw CloudError.message("Google 私钥内容不完整。") }
            let range = index..<(index + length); index += length; return range
        }
        var index = 0
        let outer = try value(&index, tag: 0x30); index = outer.lowerBound
        _ = try value(&index, tag: 0x02); _ = try value(&index, tag: 0x30)
        return Data(bytes[try value(&index, tag: 0x04)])
    }
}
