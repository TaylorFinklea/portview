// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

import PortviewClientCore

/// The CK-record ↔ struct field codec for `HostBeaconRecord`. `recordName` is deliberately NOT part
/// of the field dictionary (it's CKRecord.ID-level identity, not a CK field), so the codec covers only
/// `hostName`/`port`/`epoch`/`wantsReconnect`.
@Suite struct ReWakeBeaconRecordTests {
    @Test func roundTripsThroughFieldDictionary() {
        let original = HostBeaconRecord(
            recordName: "deadbeef",
            hostName: "Taylor's Mac",
            port: 4433,
            epoch: 1_772_000_000_000_000,
            wantsReconnect: 1
        )
        let decoded = HostBeaconRecord(recordName: original.recordName, fields: original.fields)
        #expect(decoded == original)
    }

    @Test func fieldDictionaryOmitsRecordName() {
        let record = HostBeaconRecord(recordName: "deadbeef", hostName: "Mac", port: 1, epoch: 2, wantsReconnect: 0)
        #expect(record.fields["recordName"] == nil)
    }

    @Test func decodeFailsWhenARequiredFieldIsMissing() {
        let fields: [String: Any] = ["hostName": "Mac", "port": Int64(1), "epoch": Int64(2)] // no wantsReconnect
        #expect(HostBeaconRecord(recordName: "deadbeef", fields: fields) == nil)
    }

    @Test func decodeFailsWhenAFieldHasTheWrongType() {
        let fields: [String: Any] = ["hostName": "Mac", "port": "not-a-number", "epoch": Int64(2), "wantsReconnect": Int64(0)]
        #expect(HostBeaconRecord(recordName: "deadbeef", fields: fields) == nil)
    }
}
