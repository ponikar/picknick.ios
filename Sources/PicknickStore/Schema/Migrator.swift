import Foundation

enum Migrator {
    /// Applies every migration newer than the file's current version, each in
    /// its own transaction so a failure leaves the database on the last good
    /// version rather than somewhere in between.
    static func migrate(_ connection: SQLiteConnection) throws {
        let installed = try connection.userVersion()

        for migration in Schema.migrations where migration.version > installed {
            try connection.transaction {
                try connection.execute(migration.statements)
                try connection.setUserVersion(migration.version)
            }
        }
    }
}
