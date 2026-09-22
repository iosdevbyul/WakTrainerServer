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

        #expect(
            report.lines
                .filter { !$0.hasPrefix("INFO ") }
                .allSatisfy { $0.hasPrefix("PASS ") }
        )

        #expect(
            report.lines.contains("INFO PostgreSQL TLS active=true")
        )
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
    
    
    @Test("Railway private network accepts disabled PostgreSQL TLS")
    func railwayPrivateNetwork() async throws {
        let variables = [
            "DATABASE_NETWORK": "railway-private",
            "DATABASE_URL":
                "postgresql://waktrainer_app:test@postgres.railway.internal:5432/waktrainer",
            "DATABASE_TLS": "disable"
        ]

        let policy = try DatabaseDiagnosticTLSPolicy.resolve {
            variables[$0]
        }

        let report = await DatabaseDiagnostic.run(
            tlsPolicy: policy
        ) {
            snapshot(tls: false)
        }

        #expect(report.passed)
        #expect(
            report.lines.contains("INFO PostgreSQL TLS active=false")
        )
        #expect(
            report.lines.contains("PASS TLS policy satisfied")
        )
    }

    @Test("Public database connections require active TLS")
    func publicNetworkRequiresTLS() async throws {
        let variables = [
            "DATABASE_NETWORK": "public",
            "DATABASE_URL":
                "postgresql://waktrainer_app:test@db.example.com:5432/waktrainer",
            "DATABASE_TLS": "require"
        ]

        let policy = try DatabaseDiagnosticTLSPolicy.resolve {
            variables[$0]
        }

        let report = await DatabaseDiagnostic.run(
            tlsPolicy: policy
        ) {
            snapshot(tls: false)
        }

        #expect(!report.passed)
        #expect(
            report.lines.contains("FAIL TLS policy satisfied")
        )
    }

    @Test("Public database address cannot use the private-network policy")
    func rejectsPublicHostWithPrivatePolicy() {
        let variables = [
            "DATABASE_NETWORK": "railway-private",
            "DATABASE_URL":
                "postgresql://waktrainer_app:test@db.example.com:5432/waktrainer",
            "DATABASE_TLS": "disable"
        ]

        #expect(throws: (any Error).self) {
            try DatabaseDiagnosticTLSPolicy.resolve {
                variables[$0]
            }
        }
    }
    
    
    @Test("Invalid database network configurations are rejected")
    func rejectsInvalidNetworkConfigurations() {
        let invalidConfigurations: [[String: String]] = [
            [
                "DATABASE_NETWORK": "public",
                "DATABASE_URL":
                    "postgresql://test:password@db.example.com:5432/waktrainer",
                "DATABASE_TLS": "disable"
            ],
            [
                "DATABASE_NETWORK": "public",
                "DATABASE_URL":
                    "postgresql://test:password@postgres.railway.internal:5432/waktrainer",
                "DATABASE_TLS": "require"
            ],
            [
                "DATABASE_URL":
                    "postgresql://test:password@postgres.railway.internal:5432/waktrainer",
                "DATABASE_TLS": "disable"
            ],
            [
                "DATABASE_NETWORK": "railway-private",
                "DATABASE_URL":
                    "postgresql://test:password@postgres.railway.internal:5433/waktrainer",
                "DATABASE_TLS": "disable"
            ],
            [
                "DATABASE_NETWORK": "railway-private",
                "DATABASE_URL":
                    "postgresql://test:password@postgres.railway.internal:5432/waktrainer",
                "DATABASE_TLS": "require"
            ],
            [
                "DATABASE_NETWORK": "unknown",
                "DATABASE_URL":
                    "postgresql://test:password@db.example.com:5432/waktrainer",
                "DATABASE_TLS": "require"
            ]
        ]

        for variables in invalidConfigurations {
            #expect(throws: (any Error).self) {
                try DatabaseDiagnosticTLSPolicy.resolve {
                    variables[$0]
                }
            }
        }
    }
    
    
    @Test("Public database with active TLS passes")
    func publicNetworkWithTLS() async throws {
        let variables = [
            "DATABASE_NETWORK": "public",
            "DATABASE_URL":
                "postgresql://test:password@db.example.com:5432/waktrainer",
            "DATABASE_TLS": "require"
        ]

        let policy = try DatabaseDiagnosticTLSPolicy.resolve {
            variables[$0]
        }

        let report = await DatabaseDiagnostic.run(
            tlsPolicy: policy
        ) {
            snapshot(tls: true)
        }

        #expect(report.passed)
        #expect(
            report.lines.contains("INFO PostgreSQL TLS active=true")
        )
        #expect(
            report.lines.contains("PASS TLS policy satisfied")
        )
    }
}
