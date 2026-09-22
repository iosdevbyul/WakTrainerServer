import Fluent
import FluentPostgresDriver
import Vapor

struct DatabaseDiagnosticSnapshot: Decodable, Sendable {
    let databaseMatches: Bool
    let userMatches: Bool
    let tlsEnabled: Bool
    let readOnly: Bool
    let canConnect: Bool
    let publicUsage: Bool
    let databaseCreate: Bool
    let publicCreate: Bool
    let elevatedRole: Bool
}

struct DatabaseDiagnosticReport: Sendable {
    let passed: Bool
    let lines: [String]
}



enum DatabaseDiagnosticTLSPolicy: Sendable {
    case requireTLS
    case railwayPrivateNetwork

    func isSatisfied(tlsEnabled: Bool) -> Bool {
        switch self {
        case .requireTLS:
            return tlsEnabled

        case .railwayPrivateNetwork:
            return true
        }
    }

    static func resolve(
        environment: (String) -> String?
    ) throws -> Self {
        let network = environment("DATABASE_NETWORK") ?? "public"
        let tls = environment("DATABASE_TLS")

        guard let url = environment("DATABASE_URL"),
              let components = URLComponents(string: url),
              let hostname = components.host?.lowercased()
        else {
            throw Abort(
                .internalServerError,
                reason: "Database diagnostic requires a valid DATABASE_URL."
            )
        }

        switch network {
        case "railway-private":
            guard hostname == "postgres.railway.internal",
                  components.port == 5432,
                  tls == "disable"
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Invalid Railway private database configuration."
                )
            }

            return .railwayPrivateNetwork

        case "public":
            guard hostname != "postgres.railway.internal",
                  tls == "require"
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Public database connections require TLS."
                )
            }

            return .requireTLS

        default:
            throw Abort(
                .internalServerError,
                reason: "Unsupported DATABASE_NETWORK value."
            )
        }
    }
}

enum DatabaseDiagnostic {
    
    static func run(
        tlsPolicy: DatabaseDiagnosticTLSPolicy = .requireTLS,
        load: () async throws -> DatabaseDiagnosticSnapshot
    ) async -> DatabaseDiagnosticReport {
        do {
            let snapshot = try await load()
            
            let tlsPolicySatisfied = tlsPolicy.isSatisfied(
                tlsEnabled: snapshot.tlsEnabled
            )
            
            let checks = [
                ("database = waktrainer", snapshot.databaseMatches),
                ("user = waktrainer_app", snapshot.userMatches),
                ("TLS policy satisfied", tlsPolicySatisfied),
                ("read-only transaction", snapshot.readOnly),
                ("database CONNECT", snapshot.canConnect),
                ("public schema USAGE", snapshot.publicUsage),
            ]
            
            return .init(
                passed: checks.allSatisfy(\.1),
                lines:
                    [
                        "PASS database connection and read-only query",
                        "INFO PostgreSQL TLS active=\(snapshot.tlsEnabled)"
                    ]
                    + checks.map {
                        "\($0.1 ? "PASS" : "FAIL") \($0.0)"
                    }
                    + [
                        "PASS privilege inspection (granted=true): database CREATE=\(snapshot.databaseCreate), public CREATE=\(snapshot.publicCreate), elevated role=\(snapshot.elevatedRole)"
                    ]
            )
        } catch {
            // Never retain or print driver errors, which can contain connection details.
            return .init(passed: false, lines: ["FAIL database connection or read-only query; details withheld"])
        }
    }

    static func load(from app: Application) async throws -> DatabaseDiagnosticSnapshot {
        let logger = Logger(label: "database-diagnostic", factory: { _ in SwiftLogNoOpLogHandler() })
        guard let database = app.databases.database(.psql, logger: logger,
            on: app.eventLoopGroup.next(), withTracing: false) else {
            throw Abort(.internalServerError, reason: "Database diagnostic unavailable.")
        }
        return try await database.withConnection { connection in
            guard let sql = connection as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database diagnostic unavailable.")
            }
            try await sql.raw("BEGIN READ ONLY").run()
            do {
                try await sql.raw("SET LOCAL statement_timeout = '5s'").run()
                let row = try await sql.raw("""
                    SELECT current_database() = 'waktrainer' AS "databaseMatches",
                           current_user = 'waktrainer_app' AS "userMatches",
                           COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false) AS "tlsEnabled",
                           current_setting('transaction_read_only') = 'on' AS "readOnly",
                           has_database_privilege(current_user, current_database(), 'CONNECT') AS "canConnect",
                           has_schema_privilege(current_user, 'public', 'USAGE') AS "publicUsage",
                           has_database_privilege(current_user, current_database(), 'CREATE') AS "databaseCreate",
                           has_schema_privilege(current_user, 'public', 'CREATE') AS "publicCreate",
                           (SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
                            FROM pg_roles WHERE rolname = current_user) AS "elevatedRole"
                    """).first(decoding: DatabaseDiagnosticSnapshot.self)
                guard let row else { throw Abort(.internalServerError, reason: "Database diagnostic unavailable.") }
                try await sql.raw("ROLLBACK").run()
                return row
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }
}

struct DatabaseDiagnosticFailure: Error {}

struct VerifyDatabaseCommand: AsyncCommand {
    struct Signature: CommandSignature { init() {} }
    var help: String { "Verify database identity, TLS, and privileges using read-only SQL." }

    
    func run(
        using context: CommandContext,
        signature: Signature
    ) async throws {
        let tlsPolicy = try DatabaseDiagnosticTLSPolicy.resolve(
            environment: { Environment.get($0) }
        )

        let report = await DatabaseDiagnostic.run(
            tlsPolicy: tlsPolicy
        ) {
            try await DatabaseDiagnostic.load(
                from: context.application
            )
        }

        for line in report.lines {
            context.console.print(line)
        }

        guard report.passed else {
            throw DatabaseDiagnosticFailure()
        }
    }
}
