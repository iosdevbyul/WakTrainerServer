import Vapor
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
enum Entrypoint {
    static func main() async throws {
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)
        let app = try await Application.make(environment)
        do {
            try await configure(app)
            try await app.execute()
        } catch is DatabaseDiagnosticFailure {
            try? await app.asyncShutdown()
            exit(EXIT_FAILURE)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
