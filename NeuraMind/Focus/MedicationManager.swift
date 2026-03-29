import Foundation
import GRDB

// MARK: - Medication Log Record

/// Single row in the medication_log table — one per toggle event.
struct MedicationLogRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var timestamp: Double
    var isActive: Bool

    static let databaseTableName = "medication_log"

    enum Columns: String, ColumnExpression {
        case id, timestamp, isActive
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Medication Manager

/// Tracks whether the user is currently on medication.
///
/// Persists state as an append-only event log in `medication_log` so historical
/// state can be reconstructed at any timestamp. Also mirrors the current flag to
/// UserDefaults for fast, cross-actor reads (e.g. from SummarizationEngine).
@MainActor
final class MedicationManager: ObservableObject {
    @Published private(set) var isActive: Bool = false

    private let database: AppDatabase
    private let logger = DualLogger(category: "Medication")

    /// UserDefaults key — also the source of truth for `currentState` reads
    /// from non-main-actor contexts (actor-safe, no isolation needed).
    nonisolated static let defaultsKey = "medicationActive"

    init(database: AppDatabase) {
        self.database = database
        self.isActive = MedicationManager.loadLatestState(from: database)
    }

    // MARK: - Toggle

    /// Flip the current medication state, insert a log row, and sync to UserDefaults.
    func toggle() {
        let newState = !isActive
        do {
            let record = MedicationLogRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                isActive: newState
            )
            try database.dbPool.write { db in
                try record.insert(db)
            }
            isActive = newState
            UserDefaults.standard.set(newState, forKey: Self.defaultsKey)
            logger.info("Medication toggled \(newState ? "ON" : "OFF")")
        } catch {
            logger.error("Failed to persist medication toggle: \(error.localizedDescription)")
        }
    }

    // MARK: - Historical Lookup

    /// What was the medication state at a given point in time?
    /// Walks the log backward from `date` to find the most recent toggle before it.
    func state(at date: Date) -> Bool {
        do {
            let ts = date.timeIntervalSince1970
            return try database.dbPool.read { db in
                let record = try MedicationLogRecord
                    .filter(MedicationLogRecord.Columns.timestamp <= ts)
                    .order(MedicationLogRecord.Columns.timestamp.desc)
                    .fetchOne(db)
                return record?.isActive ?? false
            }
        } catch {
            logger.error("Failed to look up medication state at \(date): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Static Access (actor-safe)

    /// Current medication state read directly from UserDefaults.
    /// Safe to call from any actor context — UserDefaults reads are thread-safe.
    nonisolated static var currentState: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    // MARK: - Private Helpers

    private static func loadLatestState(from database: AppDatabase) -> Bool {
        do {
            return try database.dbPool.read { db in
                let record = try MedicationLogRecord
                    .order(MedicationLogRecord.Columns.timestamp.desc)
                    .fetchOne(db)
                return record?.isActive ?? false
            }
        } catch {
            // DB might not have been migrated yet on very first launch — fall back to UserDefaults
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
    }
}
