import Foundation
import Darwin

struct CheckSkipped: Error { let message: String; init(_ message: String) { self.message = message } }
enum CheckLog {
    static let lock = NSLock()
    static var failures = 0
    static func record(_ message: String, file: StaticString = #file, line: UInt = #line) {
        lock.lock(); defer { lock.unlock() }
        failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}
func expectTrue(_ value: Bool, _ message: String = "Expected true", file: StaticString = #file, line: UInt = #line) { if !value { CheckLog.record(message, file: file, line: line) } }
func expectFalse(_ value: Bool, _ message: String = "Expected false", file: StaticString = #file, line: UInt = #line) { expectTrue(!value, message, file: file, line: line) }
func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) { if lhs != rhs { CheckLog.record("Values differ: \(lhs) != \(rhs)", file: file, line: line) } }
func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { expectTrue(value == nil, "Expected nil", file: file, line: line) }
func expectThrows<T>(_ body: @autoclosure () throws -> T, _ message: String = "Expected error", file: StaticString = #file, line: UInt = #line) {
    do { _ = try body(); CheckLog.record(message, file: file, line: line) } catch {}
}
func expectNoThrow(_ body: @autoclosure () throws -> Any, file: StaticString = #file, line: UInt = #line) {
    do { _ = try body() } catch { CheckLog.record("Unexpected error: \(error)", file: file, line: line) }
}
func fail(_ message: String, file: StaticString = #file, line: UInt = #line) { CheckLog.record(message, file: file, line: line) }
func required<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "CloudDockChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required value"]) }
    return value
}

@main struct CheckRunner {
    static func main() async {
        let core = CoreChecks(), s3 = S3IntegrationChecks(), gcs = GCSIntegrationChecks(), features = AuditPreviewChecks(), sharing = ShareChecks(), credentials = CredentialChecks()
        let paging = PagingChecks(), listing = ListingProtocolChecks()
        let cases: [(String, () async throws -> Void)] = [
            ("Path traversal and Unicode keys", { try core.testRejectsTraversalAndRootOperations() }),
            ("Credential isolation and redaction", { try core.testCredentialsAreExcludedFromSavedConnection() }),
            ("Connection metadata round-trip preserves Endpoint, bucket and storage mode", { try core.testConnectionMetadataRoundTripPreservesAllFields() }),
            ("Provider validation and GCS configuration", { try core.testProviderValidationAndGoogleIsolation() }),
            ("S3 file/folder name collision identity", { try core.testFileAndFolderWithSameNameHaveDistinctIdentity() }),
            ("Local default and legacy Keychain connection compatibility", { try credentials.testDefaultsAndLegacyConnectionDecoding() }),
            ("Local credential encryption, restart, permissions and integrity", { try credentials.testLocalEncryptionPersistenceAndIntegrity() }),
            ("Local credentials never call Keychain; metadata-only edits retain secrets", { try credentials.testLocalIsolationAndMetadataOnlyChanges() }),
            ("Credential migration, cleanup denial and commit rollback", { try credentials.testMigrationAndRollback() }),
            ("Audit restart persistence, connection snapshots and read exclusion", { try features.testAuditPersistsSnapshotsAndReadingDoesNotLog() }),
            ("Preview limits, unsupported formats and text decoding", { try features.testPreviewPolicyAndTextDecoding() }),
            ("Share duration limits, signed expiration and URL byte preservation", { try sharing.testExpiryBoundariesAndSignedURLPreservation() }),
            ("Google V4 download signature, expiry, local direct link and QR", { try await sharing.testGoogleSignedDownloadAndLocalDirectLink() }),
            ("QR scan returns the exact signed download URL", { try sharing.testQRCodeDecodesToExactSignedAddress() }),
            ("Audit 20,000-row indexed pagination, filters, lifecycle recovery and catch-up", { try await paging.testAuditIndexPaginationAndRecovery() }),
            ("Demand paging, cross-page search, retry and cancellation", { try await paging.testDemandPagingSearchRetryAndCancellation() }),
            ("S3/OSS listing signatures, Unicode keys and opaque cursor encoding", { try await listing.testS3OSSSignaturesAndOpaqueTokens() }),
            ("MinIO encoded names preserve spaces, plus signs and literal percent escapes", { try await listing.testMinIOEncodedNamesKeepDistinctObjectKeys() }),
            ("Local endpoints use consistent bucket paths for listing and transfers", { try await listing.testLocalEndpointsUseConsistentBucketPaths() }),
            ("Google PKCS8 JWT signature, token reuse and object pages", { try await listing.testGoogleJWTAndPagedObjects() }),
            ("Native S3 pagination and collision checks beyond the current page", { try await paging.testNativePagesAgainstS3Fixture() }),
            ("Local S3 compatibility: listed keys drive transfers and deletion", { try await s3.testListedKeysDriveTransfersAndDeletion() }),
            ("Local GCS compatibility: listed keys drive transfers and deletion", { try await gcs.testLocalGCSCompatibility() }),
            ("S3 round trip, folders, rename, delete and signing", { try await s3.testS3RoundTripDirectoriesRenameDeleteAndPresigning() }),
            ("Skip, forced overwrite, mixed directory and bounded cloud preview", { try await s3.testTransferOutcomesAndBoundedPreview() }),
            ("Pause, resume and cancellation", { try await s3.testCancellationStopsLongTransfer() })
        ]
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--filter") else {
            print("Usage: CloudDockChecks [--filter name]"); exit(2)
        }
        let selected = arguments.isEmpty ? cases : cases.filter { $0.0.contains(arguments[1]) }
        guard !selected.isEmpty else { print("No matching checks"); exit(2) }
        var passed = 0, skipped = 0
        for (name, test) in selected {
            let before = CheckLog.failures
            do {
                try await test()
                if CheckLog.failures == before { print("PASS: \(name)"); passed += 1 }
            } catch let error as CheckSkipped { print("SKIP: \(name): \(error.message)"); skipped += 1 }
            catch { CheckLog.record("\(name): \(error.localizedDescription)") }
        }
        print("\(passed) passed, \(skipped) skipped, \(CheckLog.failures) failures")
        if CheckLog.failures > 0 { exit(1) }
    }
}
