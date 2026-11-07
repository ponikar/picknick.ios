import Foundation

struct Migration {
    let version: Int32
    let statements: String
}

/// Forward-only schema versions applied through `PRAGMA user_version`.
///
/// A migration is never edited once shipped; correcting a mistake means adding
/// the next version.
enum Schema {
    static let migrations: [Migration] = [
        Migration(version: 1, statements: initialSchema),
        Migration(version: 2, statements: placeNames),
    ]

    static var currentVersion: Int32 {
        migrations.map(\.version).max() ?? 0
    }

    /// Assets and their derived signals. Every derived table cascades from
    /// `asset`, so removing a photo from the library is a single delete.
    private static let initialSchema = """
    CREATE TABLE asset (
        id            TEXT    PRIMARY KEY,
        kind          INTEGER NOT NULL,
        traits        INTEGER NOT NULL,
        created_at    REAL,
        modified_at   REAL,
        pixel_width   INTEGER NOT NULL,
        pixel_height  INTEGER NOT NULL,
        latitude      REAL,
        longitude     REAL,
        is_favorite   INTEGER NOT NULL,
        is_hidden     INTEGER NOT NULL,
        duration      REAL    NOT NULL
    ) STRICT;

    CREATE INDEX asset_by_recency ON asset(created_at DESC);

    CREATE TABLE asset_stage (
        asset_id     TEXT    NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
        stage        TEXT    NOT NULL,
        version      INTEGER NOT NULL,
        completed_at REAL    NOT NULL,
        PRIMARY KEY (asset_id, stage)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE stage_failure (
        asset_id     TEXT    NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
        stage        TEXT    NOT NULL,
        reason       TEXT    NOT NULL,
        is_permanent INTEGER NOT NULL,
        occurred_at  REAL    NOT NULL,
        PRIMARY KEY (asset_id, stage)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE embedding (
        asset_id   TEXT    PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
        model      TEXT    NOT NULL,
        dimensions INTEGER NOT NULL,
        vector     BLOB    NOT NULL
    ) STRICT;

    CREATE TABLE label (
        asset_id   TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
        identifier TEXT NOT NULL,
        confidence REAL NOT NULL,
        PRIMARY KEY (asset_id, identifier)
    ) STRICT, WITHOUT ROWID;

    CREATE INDEX label_by_identifier ON label(identifier);

    CREATE TABLE recognized_text (
        asset_id TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
        content  TEXT NOT NULL,
        geometry BLOB NOT NULL
    ) STRICT;

    CREATE VIRTUAL TABLE asset_search USING fts5(
        asset_id UNINDEXED,
        content,
        labels,
        tokenize = 'unicode61 remove_diacritics 2'
    );
    """

    /// Place names per asset, searchable through a new `place` column.
    ///
    /// FTS5 tables cannot gain a column, so `asset_search` is rebuilt from the
    /// tables that feed it.
    private static let placeNames = """
    CREATE TABLE asset_place (
        asset_id TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
        terms    TEXT NOT NULL
    ) STRICT;

    DROP TABLE asset_search;

    CREATE VIRTUAL TABLE asset_search USING fts5(
        asset_id UNINDEXED,
        content,
        labels,
        place,
        tokenize = 'unicode61 remove_diacritics 2'
    );

    INSERT INTO asset_search (asset_id, content, labels, place)
    SELECT
        a.id,
        COALESCE((SELECT content FROM recognized_text WHERE asset_id = a.id), ''),
        COALESCE((SELECT group_concat(identifier, ' ') FROM label WHERE asset_id = a.id), ''),
        ''
    FROM asset a
    WHERE EXISTS (SELECT 1 FROM recognized_text WHERE asset_id = a.id)
       OR EXISTS (SELECT 1 FROM label WHERE asset_id = a.id);

    -- Place names come from the host app's gazetteer, not SQL. Clearing the
    -- fingerprint makes the next sync re-read these assets and name them.
    UPDATE asset SET modified_at = NULL WHERE latitude IS NOT NULL;
    """
}
