@testable import WakTrainerServer
import Testing

@Suite("Maintenance policy")
struct MaintenancePolicyTests {
    @Test func retentionValidation() throws {
        #expect(try MaintenancePolicy.configured(retentionDays: nil).auditRetentionDays == 90)
        #expect(try MaintenancePolicy.configured(retentionDays: "90").auditRetentionDays == 90)
        #expect(try MaintenancePolicy.configured(retentionDays: "180").auditRetentionDays == 180)
        for invalid in ["89", "0", "-1", "", "text", "90.5", "365001", "99999999999999999999999"] {
            #expect(throws: (any Error).self) { try MaintenancePolicy.configured(retentionDays: invalid) }
        }
    }
}
