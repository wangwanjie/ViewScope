import Foundation
import GRDB
import ViewScopeServer

struct RecentHostRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "recent_hosts"

    var bundleIdentifier: String
    var displayName: String
    var serverIdentifier: String
    var version: String
    var build: String
    var processIdentifier: Int32
    var lastConnectedAt: Date

    var id: String { bundleIdentifier }
}

struct CaptureHistoryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "capture_history"

    var id: Int64?
    var bundleIdentifier: String
    var capturedAt: Date
    var nodeCount: Int
    var windowCount: Int
    var captureDurationMilliseconds: Int
}

final class AppDatabase {
    private let dbQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.readonly = false
        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try migrator.migrate(dbQueue)
    }

    func close() throws {
        try dbQueue.close()
    }

    func recentHosts() throws -> [RecentHostRecord] {
        try dbQueue.read { db in
            try RecentHostRecord
                .order(Column("lastConnectedAt").desc)
                .fetchAll(db)
        }
    }

    func recordConnection(host: ViewScopeHostAnnouncement) throws {
        let record = RecentHostRecord(
            bundleIdentifier: host.bundleIdentifier,
            displayName: host.displayName,
            serverIdentifier: host.identifier,
            version: host.version,
            build: host.build,
            processIdentifier: host.processIdentifier,
            lastConnectedAt: Date()
        )

        try dbQueue.write { db in
            try record.save(db)
        }
    }

    func recordCapture(for host: ViewScopeHostAnnouncement, summary: ViewScopeCaptureSummary) throws {
        let record = CaptureHistoryRecord(
            id: nil,
            bundleIdentifier: host.bundleIdentifier,
            capturedAt: Date(),
            nodeCount: summary.nodeCount,
            windowCount: summary.windowCount,
            captureDurationMilliseconds: summary.captureDurationMilliseconds
        )

        try dbQueue.write { db in
            try record.insert(db)
            try db.execute(
                sql: "DELETE FROM capture_history WHERE id NOT IN (SELECT id FROM capture_history ORDER BY capturedAt DESC LIMIT 250)"
            )
        }
    }

    func captureInsight(for bundleIdentifier: String) throws -> CaptureHistoryInsight {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    COUNT(*) AS totalCount,
                    AVG(captureDurationMilliseconds) AS averageDuration,
                    (SELECT captureDurationMilliseconds
                     FROM capture_history
                     WHERE bundleIdentifier = ?
                     ORDER BY capturedAt DESC
                     LIMIT 1) AS latestDuration
                FROM capture_history
                WHERE bundleIdentifier = ?
                """,
                arguments: [bundleIdentifier, bundleIdentifier]
            )

            return CaptureHistoryInsight(
                totalCaptures: row?["totalCount"] ?? 0,
                averageDurationMilliseconds: Int((row?["averageDuration"] as Double?) ?? 0),
                mostRecentDurationMilliseconds: row?["latestDuration"] ?? 0
            )
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createRecentHosts") { db in
            try db.create(table: "recent_hosts", ifNotExists: true) { table in
                table.column("bundleIdentifier", .text).notNull().primaryKey()
                table.column("displayName", .text).notNull()
                table.column("serverIdentifier", .text).notNull()
                table.column("version", .text).notNull()
                table.column("build", .text).notNull()
                table.column("processIdentifier", .integer).notNull()
                table.column("lastConnectedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("createCaptureHistory") { db in
            try db.create(table: "capture_history", ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("bundleIdentifier", .text).notNull().indexed()
                table.column("capturedAt", .datetime).notNull().indexed()
                table.column("nodeCount", .integer).notNull()
                table.column("windowCount", .integer).notNull()
                table.column("captureDurationMilliseconds", .integer).notNull()
            }
        }

        return migrator
    }
}
