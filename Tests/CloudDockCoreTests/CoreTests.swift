import Foundation
import CloudDockCore

final class CoreChecks {
    func testRejectsTraversalAndRootOperations() throws {
        for path in ["../secret", "folder/../../secret", "/absolute", "a//b", "a/./b", "a\\b", "x\0y"] {
            expectThrows(try ObjectPath.remote(bucket: "bucket", key: path), path)
        }
        expectThrows(try ObjectPath.remote(bucket: "", key: "somewhere"))
        expectThrows(try ObjectPath.remote(bucket: "a/b"))
        expectEqual(try ObjectPath.remote(bucket: "bucket", key: "资料/图片 01.png"), "cloud:bucket/资料/图片 01.png")
        expectEqual(try ObjectPath.remote(bucket: "bucket", key: "empty/"), "cloud:bucket/empty/")
    }
    func testCredentialsAreExcludedFromSavedConnection() throws {
        let c = Connection(name: "test", endpoint: "http://127.0.0.1:9000")
        let secret = Credentials(accessKey: "fake-access-key", secretKey: "fake-secret-key", sessionToken: "fake-session-token")
        let encoded = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        expectFalse(encoded.contains(secret.secretKey))
        expectFalse(encoded.contains("secretKey"))
        let env = StorageEngine().environment(connection: c, credentials: secret)
        expectEqual(env["RCLONE_CONFIG_CLOUD_ACCESS_KEY_ID"], secret.accessKey)
        expectEqual(env["RCLONE_CONFIG_CLOUD_ENV_AUTH"], "false")
        expectEqual(env["RCLONE_CONFIG_CLOUD_SESSION_TOKEN"], secret.sessionToken)
        expectNil(env["AWS_PROFILE"])
        expectFalse(secret.redact("failed with fake-secret-key fake-session-token fake-access-key").contains("fake-"))
    }
    func testConnectionMetadataRoundTripPreservesAllFields() throws {
        let original = Connection(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, name: "OSS fixture",
                                  provider: .aliyun, endpoint: "http://oss-cn-hangzhou.example.invalid", region: "oss-cn-hangzhou",
                                  bucket: "fixture-bucket", projectNumber: "123456", pathStyle: false, credentialStorage: .local)
        let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(original))
        expectEqual(decoded, original)
    }
    func testProviderValidationAndGoogleIsolation() throws {
        expectTrue(Provider.newConnectionCases.contains(.google))
        expectTrue(Provider.newConnectionCases.contains(.aws))
        let secrets = Credentials(accessKey: "local", secretKey: "local-secret")
        expectThrows(try Connection(name: "bad", endpoint: "http://user:password@example.com").validate(secrets))
        expectThrows(try Connection(name: "bad", endpoint: "https://example.com/bucket").validate(secrets))
        expectThrows(try Connection(name: "missing", provider: .minio).validate(secrets))
        expectNoThrow(try Connection(name: "aws", provider: .aws, region: "us-east-1").validate(secrets))
        let gcs = Connection(name: "gcs", provider: .google)
        expectThrows(try gcs.validate(secrets))
        let gcsSecrets = Credentials(serviceAccountJSON: "{\"type\":\"service_account\",\"client_email\":\"test@example.invalid\",\"private_key\":\"fake-test-key\"}")
        expectNoThrow(try gcs.validate(gcsSecrets))
        let env = StorageEngine().environment(connection: gcs, credentials: gcsSecrets)
        expectEqual(env["RCLONE_CONFIG_CLOUD_TYPE"], "google cloud storage")
        expectNil(env["RCLONE_CONFIG_CLOUD_ACCESS_KEY_ID"])
        expectEqual(env["RCLONE_CONFIG_CLOUD_SERVICE_ACCOUNT_CREDENTIALS"], gcsSecrets.serviceAccountJSON)
        let local = Connection(name: "local gcs", provider: .google, endpoint: "http://127.0.0.1:4443/storage/v1/", projectNumber: "0")
        expectNoThrow(try local.validate(Credentials()))
        let localEnv = StorageEngine().environment(connection: local, credentials: gcsSecrets)
        expectEqual(localEnv["RCLONE_CONFIG_CLOUD_ENDPOINT"], local.endpoint)
        expectEqual(localEnv["RCLONE_CONFIG_CLOUD_ANONYMOUS"], "true")
        for suffix in ["", "/", "/storage/v1", "/storage/v1/"] {
            let legacy = Connection(name: "saved GCS", provider: .google, endpoint: "http://localhost:4443" + suffix, projectNumber: "demo-bucket")
            let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(legacy))
            let env = StorageEngine().environment(connection: decoded, credentials: Credentials())
            expectEqual(env["RCLONE_CONFIG_CLOUD_ENDPOINT"], "http://localhost:4443/storage/v1/")
            expectEqual(env["RCLONE_CONFIG_CLOUD_PROJECT_NUMBER"], "0")
            expectEqual(decoded.endpoint, legacy.endpoint)
        }
        expectNil(env["RCLONE_CONFIG_CLOUD_ANONYMOUS"])
    }
    func testFileAndFolderWithSameNameHaveDistinctIdentity() throws {
        let json = "[{\"Path\":\"same\",\"Name\":\"same\",\"Size\":1,\"ModTime\":\"\",\"IsDir\":false},{\"Path\":\"same\",\"Name\":\"same\",\"Size\":-1,\"ModTime\":\"\",\"IsDir\":true}]"
        let entries = try JSONDecoder().decode([RemoteEntry].self, from: Data(json.utf8))
        expectEqual(Set(entries.map(\.id)).count, 2)
    }
}
