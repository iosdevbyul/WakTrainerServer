@testable import WakTrainerServer
import Foundation
import Testing
import VaporTesting

@Suite("Read-only database diagnostic")
struct DatabaseDiagnosticTests {
    private func snapshot(database: Bool = true, user: Bool = true, tls: Bool = true,
                          readOnly: Bool = true, connect: Bool = true, usage: Bool = true) -> DatabaseDiagnosticSnapshot {
        .init(databaseMatches: database, userMatches: user, tlsEnabled: tls, readOnly: readOnly,
              canConnect: connect, publicUsage: usage, databaseCreate: false, publicCreate: false, elevatedRole: false)
    }

    @Test("Expected identity, TLS and runtime permissions pass without CREATE privileges")
    func success() async {
        let report = await DatabaseDiagnostic.run { snapshot() }
        #expect(report.passed)
        #expect(report.lines.allSatisfy { $0.hasPrefix("PASS ") })
    }

    @Test("Incorrect identity, disabled TLS or missing permissions fail", arguments: 0..<6)
    func invalidState(field: Int) async {
        let report = await DatabaseDiagnostic.run {
            snapshot(database: field != 0, user: field != 1, tls: field != 2,
                     readOnly: field != 3, connect: field != 4, usage: field != 5)
        }
        #expect(!report.passed)
        #expect(report.lines.filter { $0.hasPrefix("FAIL ") }.count == 1)
    }

    @Test("Driver failures are replaced by a fixed diagnostic")
    func failure() async {
        let report = await DatabaseDiagnostic.run {
            throw NSError(domain: "postgres://private-user:private-password@private-host/private-db", code: 1)
        }
        #expect(!report.passed)
        #expect(report.lines == ["FAIL database connection or read-only query; details withheld"])
    }
}
