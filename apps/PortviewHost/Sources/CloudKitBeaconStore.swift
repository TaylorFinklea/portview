// SPDX-License-Identifier: Apache-2.0
import CloudKit
import Foundation
import PortviewClientCore
import PortviewHostCore
import Security

/// CloudKit-backed `BeaconStore` — the app-edge implementation behind `HostBeaconWriter` (spec:
/// `docs/superpowers/specs/2026-07-01-cloudkit-rewake.md` §0-§1). All records live in the user's own
/// private database (zero third-party server) in the custom `PortviewSignals` zone; the client's
/// `CKRecordZoneSubscription` on that zone turns each save into a silent push. Stateless: containers
/// and databases are looked up per call, and the writer serializes calls, so plain `Sendable` holds.
final class CloudKitBeaconStore: BeaconStore, Sendable {
    /// Shared with the iOS client (both targets carry the iCloud entitlement for this container).
    static let containerIdentifier = "iCloud.dev.finklea.portview"
    static let zoneName = "PortviewSignals"
    static let recordType = "HostBeacon"

    /// Thrown (and log-and-dropped by the writer) instead of touching CKContainer when the build was
    /// signed without the iCloud entitlement — `CKContainer(identifier:)` raises an uncatchable ObjC
    /// exception in that case, and a missing entitlement must degrade to "feature unavailable", never
    /// crash hosting. The entitlement is opt-in until container provisioning is set up (see
    /// PORTVIEW_HOST_ENTITLEMENTS in apps/Portview.xcconfig).
    enum EdgeError: Error {
        case missingICloudEntitlement
    }

    /// Whether this process was signed with the CloudKit entitlement (read once via SecTask).
    private static let entitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
    }()

    private var database: CKDatabase {
        CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
    }
    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Idempotent `CKModifyRecordZonesOperation`: saving an existing zone succeeds, so the writer can
    /// call this before its first write AND again on a `zoneNotFound` retry without special-casing.
    func createZone() async throws {
        guard Self.entitled else { throw EdgeError.missingICloudEntitlement }
        let results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        for result in results.saveResults.values { _ = try result.get() }
    }

    /// Upsert by `recordName` (the host pin fingerprint hex) with save policy `.changedKeys` — the
    /// `.ifServerRecordUnchanged` default would fail every write after the first with a
    /// server-record-changed conflict (spec §1). A missing zone is mapped to
    /// `BeaconStoreError.zoneNotFound` so the writer runs its create-then-retry.
    func save(_ beacon: HostBeaconRecord) async throws {
        guard Self.entitled else { throw EdgeError.missingICloudEntitlement }
        let record = CKRecord(recordType: Self.recordType,
                              recordID: CKRecord.ID(recordName: beacon.recordName, zoneID: zoneID))
        for (key, value) in beacon.fields {
            record[key] = value as? any CKRecordValueProtocol
        }
        do {
            let results = try await database.modifyRecords(saving: [record], deleting: [],
                                                           savePolicy: .changedKeys)
            for result in results.saveResults.values { _ = try result.get() }
        } catch {
            throw Self.isZoneNotFound(error) ? BeaconStoreError.zoneNotFound : error
        }
    }

    /// `zoneNotFound` can surface as the top-level `CKError` or buried per-item in a `partialFailure`.
    private static func isZoneNotFound(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .zoneNotFound { return true }
        guard ckError.code == .partialFailure, let partial = ckError.partialErrorsByItemID else { return false }
        return partial.values.contains { ($0 as? CKError)?.code == .zoneNotFound }
    }
}
