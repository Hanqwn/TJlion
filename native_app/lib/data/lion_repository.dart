import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

/// Owns the app's local SQLite database and its media files.
///
/// The first open creates an empty database from the bundled schema asset.
/// Media content is kept in `media/<media_key>` files; SQLite stores owner
/// metadata and a relative path. The original `file_data` column remains empty
/// for schema v2 compatibility.
class LionRepository {
  LionRepository._({
    required Database database,
    required Directory supportDirectory,
    required File databaseFile,
  }) : _database = database,
       _supportDirectory = supportDirectory,
       _databaseFile = databaseFile;

  static const int schemaVersion = 5;
  static const String defaultSchemaAsset = 'assets/schema.sql';
  static const String databaseFileName = 'lion_manager.sqlite3';
  static const String _mediaDirectoryName = 'media';

  static final Random _random = Random.secure();

  Database _database;
  final Directory _supportDirectory;
  final File _databaseFile;
  bool _closed = false;

  String get databasePath => _databaseFile.path;
  Directory get supportDirectory => _supportDirectory;

  /// Opens the app-support database, creating an empty one from the schema on
  /// first launch. No populated seed database is copied into application data.
  static Future<LionRepository> open({
    String schemaAssetPath = defaultSchemaAsset,
  }) async {
    final supportDirectory = await getApplicationSupportDirectory();
    await supportDirectory.create(recursive: true);
    final databaseFile = File(p.join(supportDirectory.path, databaseFileName));

    if (!await databaseFile.exists()) {
      final schemaScript = await rootBundle.loadString(schemaAssetPath);
      final installFile = File(
        p.join(
          supportDirectory.path,
          '$databaseFileName.initialize-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}',
        ),
      );
      Database? initialDatabase;
      try {
        initialDatabase = sqlite3.open(installFile.path);
        _prepareDatabase(initialDatabase);
        _executeSchemaScript(initialDatabase, schemaScript);
        _migrateDatabase(initialDatabase);
        initialDatabase.dispose();
        initialDatabase = null;
        try {
          if (!await databaseFile.exists()) {
            await installFile.rename(databaseFile.path);
          }
        } on FileSystemException {
          // Another first-launch opener may have initialized the database.
          if (!await databaseFile.exists()) rethrow;
        }
      } catch (_) {
        initialDatabase?.dispose();
        rethrow;
      }
    }

    final database = sqlite3.open(databaseFile.path);
    try {
      _prepareDatabase(database);
      _migrateDatabase(database);
      final repository = LionRepository._(
        database: database,
        supportDirectory: supportDirectory,
        databaseFile: databaseFile,
      );
      await repository._moveEmbeddedMediaToFiles(database);
      return repository;
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }

  static void _prepareDatabase(Database database) {
    database.execute('PRAGMA foreign_keys = ON');
    // Keep database exports as ordinary, self-contained SQLite files.
    database.select('PRAGMA journal_mode = DELETE');
  }

  static void _executeSchemaScript(Database database, String script) {
    for (final statement in script.split(';')) {
      final sql = statement.trim();
      if (sql.isNotEmpty) database.execute(sql);
    }
  }

  static void _migrateDatabase(Database database) {
    final versionRow = database.select('PRAGMA user_version').first;
    final version = (versionRow['user_version'] as num?)?.toInt() ?? 0;
    if (version > schemaVersion) {
      throw StateError(
        'Database schema version $version is newer than this app supports ($schemaVersion).',
      );
    }
    if (version == schemaVersion && _hasCompleteV5Schema(database)) return;

    database.execute('BEGIN IMMEDIATE');
    try {
      if (version < 2) {
        for (final statement in _createTableStatements) {
          database.execute(statement);
        }
        _ensureV2Columns(database);
        for (final statement in _createIndexStatements) {
          database.execute(statement);
        }
        database.execute('PRAGMA user_version = 2');
      }
      if (version < 3) {
        database.execute('''
          CREATE TABLE IF NOT EXISTS media_file_paths (
            media_key TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL UNIQUE,
            updated_at TEXT NOT NULL
          )
        ''');
        database.execute('''
          INSERT OR IGNORE INTO media_file_paths (media_key, relative_path, updated_at)
          SELECT media_key, 'media/' || media_key, created_at
          FROM media_assets WHERE media_key <> ''
        ''');
        database.execute('PRAGMA user_version = 3');
      }
      if (version < 4) {
        final memberColumns = database
            .select('PRAGMA table_info(members)')
            .map((row) => row['name'].toString())
            .toSet();
        if (!memberColumns.contains('position')) {
          database.execute(
            "ALTER TABLE members ADD COLUMN position TEXT NOT NULL DEFAULT ''",
          );
        }
        database.execute('''
          CREATE TABLE media_assets_v4 (
            id INTEGER PRIMARY KEY,
            media_key TEXT NOT NULL UNIQUE,
            owner_type TEXT NOT NULL CHECK (
              owner_type IN ('routine', 'event', 'document', 'plan', 'training_session')
            ),
            owner_id INTEGER NOT NULL,
            role TEXT NOT NULL DEFAULT 'attachment',
            title TEXT NOT NULL,
            file_name TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            file_data BLOB NOT NULL DEFAULT X'',
            file_size INTEGER NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        database.execute('''
          INSERT INTO media_assets_v4
            (id, media_key, owner_type, owner_id, role, title, file_name,
             mime_type, file_data, file_size, created_at)
          SELECT id, media_key, owner_type, owner_id, role, title, file_name,
                 mime_type, file_data, file_size, created_at
          FROM media_assets
        ''');
        database.execute('DROP TABLE media_assets');
        database.execute('ALTER TABLE media_assets_v4 RENAME TO media_assets');
        database.execute(
          'CREATE INDEX IF NOT EXISTS idx_media_owner ON media_assets(owner_type, owner_id)',
        );
        database.execute('PRAGMA user_version = 4');
      }
      _ensureV5Schema(database);
      database.execute('PRAGMA user_version = 5');
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  static bool _hasCompleteV5Schema(Database database) {
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'].toString())
        .toSet();
    if (!const {
      'member_profiles',
      'member_profile_student_ids',
      'recurring_activities',
      'inventory_items',
      'inventory_movements',
      'media_file_paths',
    }.every(tables.contains)) {
      return false;
    }
    Set<String> columns(String table) => database
        .select('PRAGMA table_info($table)')
        .map((row) => row['name'].toString())
        .toSet();
    return const {'person_id', 'contact'}.every(columns('members').contains) &&
        const {
          'semester_id',
          'recurring_activity_id',
          'event_type',
        }.every(columns('events').contains) &&
        const {'category', 'unit'}.every(columns('inventory_items').contains);
  }

  static void _ensureV5Schema(Database database) {
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'].toString())
        .toSet();
    final originalMemberColumns = database
        .select('PRAGMA table_info(members)')
        .map((row) => row['name'].toString())
        .toSet();
    final hadMemberProfiles = originalMemberColumns.contains('person_id');

    if (tables.contains('people') && !tables.contains('member_profiles')) {
      database.execute('ALTER TABLE people RENAME TO member_profiles');
    }
    database.execute('''
      CREATE TABLE IF NOT EXISTS member_profiles (
        id INTEGER PRIMARY KEY,
        display_name TEXT NOT NULL,
        birthday TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    database.execute('''
      CREATE TABLE IF NOT EXISTS media_file_paths (
        media_key TEXT PRIMARY KEY,
        relative_path TEXT NOT NULL UNIQUE,
        updated_at TEXT NOT NULL
      )
    ''');
    database.execute('''
      INSERT OR IGNORE INTO media_file_paths (media_key, relative_path, updated_at)
      SELECT media_key, 'media/' || media_key, created_at
      FROM media_assets WHERE media_key <> ''
    ''');

    final memberColumns = database
        .select('PRAGMA table_info(members)')
        .map((row) => row['name'].toString())
        .toSet();
    if (!memberColumns.contains('person_id')) {
      database.execute(
        'ALTER TABLE members ADD COLUMN person_id INTEGER REFERENCES member_profiles(id)',
      );
    }
    if (!memberColumns.contains('contact')) {
      database.execute(
        "ALTER TABLE members ADD COLUMN contact TEXT NOT NULL DEFAULT ''",
      );
    }

    database.execute('''
      CREATE TABLE IF NOT EXISTS member_profile_student_ids (
        normalized_student_no TEXT PRIMARY KEY,
        profile_id INTEGER NOT NULL REFERENCES member_profiles(id) ON DELETE CASCADE,
        created_at TEXT NOT NULL
      )
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_member_profile_student_ids_profile
      ON member_profile_student_ids(profile_id)
    ''');

    database.execute('''
      CREATE TABLE IF NOT EXISTS recurring_activities (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        activity_type TEXT NOT NULL DEFAULT 'other',
        description TEXT NOT NULL DEFAULT '',
        active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    final eventColumns = database
        .select('PRAGMA table_info(events)')
        .map((row) => row['name'].toString())
        .toSet();
    if (!eventColumns.contains('semester_id')) {
      database.execute(
        'ALTER TABLE events ADD COLUMN semester_id INTEGER REFERENCES semesters(id) ON DELETE SET NULL',
      );
    }
    if (!eventColumns.contains('recurring_activity_id')) {
      database.execute(
        'ALTER TABLE events ADD COLUMN recurring_activity_id INTEGER REFERENCES recurring_activities(id) ON DELETE SET NULL',
      );
    }
    if (!eventColumns.contains('event_type')) {
      database.execute(
        "ALTER TABLE events ADD COLUMN event_type TEXT NOT NULL DEFAULT 'other'",
      );
    }

    database.execute('''
      CREATE TABLE IF NOT EXISTS inventory_items (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT '',
        unit TEXT NOT NULL DEFAULT '',
        current_quantity INTEGER NOT NULL DEFAULT 0 CHECK (current_quantity >= 0),
        location TEXT NOT NULL DEFAULT '',
        condition TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    final inventoryItemColumns = database
        .select('PRAGMA table_info(inventory_items)')
        .map((row) => row['name'].toString())
        .toSet();
    if (!inventoryItemColumns.contains('category')) {
      database.execute(
        "ALTER TABLE inventory_items ADD COLUMN category TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!inventoryItemColumns.contains('unit')) {
      database.execute(
        "ALTER TABLE inventory_items ADD COLUMN unit TEXT NOT NULL DEFAULT ''",
      );
    }
    database.execute('''
      CREATE TABLE IF NOT EXISTS inventory_movements (
        id INTEGER PRIMARY KEY,
        item_id INTEGER NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
        movement_type TEXT NOT NULL CHECK (
          movement_type IN ('received', 'purchased', 'found', 'lost', 'stolen', 'disposed', 'adjustment')
        ),
        quantity_delta INTEGER NOT NULL CHECK (quantity_delta <> 0),
        movement_date TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        CHECK (
          (movement_type IN ('received', 'purchased', 'found') AND quantity_delta > 0) OR
          (movement_type IN ('lost', 'stolen', 'disposed') AND quantity_delta < 0) OR
          movement_type = 'adjustment'
        )
      )
    ''');

    // v4 rows have no identity link. Match nonblank identifiers after trim,
    // internal whitespace removal, and case folding. A blank-ID row always
    // receives its own profile; names and birthdays never merge people.
    final members = database.select('''
      SELECT id, person_id, student_no, name, birthday
      FROM members
      ORDER BY semester_id, id
    ''');
    for (final row in members) {
      final memberId = (row['id'] as num).toInt();
      final existingPersonId = row['person_id'] == null
          ? null
          : (row['person_id'] as num).toInt();
      final studentNo = row['student_no']?.toString() ?? '';
      final studentKey = _normalizedStudentNo(studentNo);
      final name = row['name']?.toString() ?? '';
      final birthday = row['birthday']?.toString() ?? '';
      final now = _now();

      int? profileId = existingPersonId;
      if (studentKey.isNotEmpty) {
        final mapped = database.select(
          'SELECT profile_id FROM member_profile_student_ids WHERE normalized_student_no = ?',
          [studentKey],
        );
        if (mapped.isNotEmpty) {
          profileId = (mapped.first['profile_id'] as num).toInt();
        }
      } else if (!hadMemberProfiles) {
        // This branch is only for a migration from the old roster schema.
        // Each no-ID row stays independent, even when names match.
        profileId = null;
      }

      if (profileId == null) {
        database.execute(
          '''INSERT INTO member_profiles
             (display_name, birthday, created_at, updated_at)
             VALUES (?, ?, ?, ?)''',
          [name, birthday, now, now],
        );
        profileId = database.lastInsertRowId;
      }

      database.execute('UPDATE members SET person_id = ? WHERE id = ?', [
        profileId,
        memberId,
      ]);
      if (studentKey.isNotEmpty) {
        database.execute(
          '''
          INSERT OR IGNORE INTO member_profile_student_ids
            (normalized_student_no, profile_id, created_at)
          VALUES (?, ?, ?)
        ''',
          [studentKey, profileId, now],
        );
        final canonical = database.select(
          'SELECT profile_id FROM member_profile_student_ids WHERE normalized_student_no = ?',
          [studentKey],
        );
        final canonicalProfileId = (canonical.first['profile_id'] as num)
            .toInt();
        if (canonicalProfileId != profileId) {
          database.execute('UPDATE members SET person_id = ? WHERE id = ?', [
            canonicalProfileId,
            memberId,
          ]);
        }
      }
    }

    // Older development builds created a uniqueness rule that could reject
    // duplicate source roster rows. Keep the lookup index while allowing all
    // original term rows to remain linked to the same stable profile.
    database.execute('DROP INDEX IF EXISTS idx_members_semester_person');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_members_semester_person
      ON members(semester_id, person_id)
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_members_person ON members(person_id)
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_events_semester_type
      ON events(semester_id, event_type, event_date DESC)
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_events_recurring_activity
      ON events(recurring_activity_id, event_date DESC)
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_inventory_movements_item_date
      ON inventory_movements(item_id, movement_date DESC, id DESC)
    ''');
  }

  static String _normalizedStudentNo(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), '').toUpperCase();

  static const List<String> _createTableStatements = [
    '''CREATE TABLE IF NOT EXISTS semesters (
      id INTEGER PRIMARY KEY,
      label TEXT NOT NULL UNIQUE,
      start_date TEXT,
      end_date TEXT,
      is_current INTEGER NOT NULL DEFAULT 0 CHECK (is_current IN (0, 1))
    )''',
    '''CREATE TABLE IF NOT EXISTS member_profiles (
      id INTEGER PRIMARY KEY,
      display_name TEXT NOT NULL,
      birthday TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS members (
      id INTEGER PRIMARY KEY,
      semester_id INTEGER NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
      person_id INTEGER REFERENCES member_profiles(id),
      student_no TEXT NOT NULL DEFAULT '',
      name TEXT NOT NULL,
      grade TEXT NOT NULL DEFAULT '',
      major TEXT NOT NULL DEFAULT '',
      position TEXT NOT NULL DEFAULT '',
      birthday TEXT NOT NULL DEFAULT '',
      contact TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
      UNIQUE (semester_id, student_no, name)
    )''',
    '''CREATE TABLE IF NOT EXISTS attendance_sessions (
      id INTEGER PRIMARY KEY,
      semester_id INTEGER NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
      session_date TEXT NOT NULL,
      start_time TEXT NOT NULL DEFAULT '18:00',
      end_time TEXT NOT NULL DEFAULT '20:00',
      title TEXT NOT NULL DEFAULT '狮队训练',
      notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS attendance_records (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL REFERENCES attendance_sessions(id) ON DELETE CASCADE,
      member_id INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
      status TEXT NOT NULL CHECK (status IN ('present', 'absent', 'pending')),
      note TEXT NOT NULL DEFAULT '',
      UNIQUE (session_id, member_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS routines (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      music TEXT NOT NULL DEFAULT '',
      movements TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      event_date TEXT NOT NULL DEFAULT '',
      location TEXT NOT NULL DEFAULT '',
      summary TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS event_members (
      event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
      member_id INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
      PRIMARY KEY (event_id, member_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS documents (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      document_type TEXT NOT NULL DEFAULT '通讯稿',
      document_date TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '',
      legacy_asset_id INTEGER,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS training_plans (
      id INTEGER PRIMARY KEY,
      semester_id INTEGER NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      legacy_asset_id INTEGER,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS finance_entries (
      id INTEGER PRIMARY KEY,
      transaction_date TEXT NOT NULL,
      entry_type TEXT NOT NULL CHECK (entry_type IN ('income', 'expense', 'wage')),
      title TEXT NOT NULL,
      amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
      member_id INTEGER REFERENCES members(id) ON DELETE SET NULL,
      notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS media_assets (
      id INTEGER PRIMARY KEY,
      media_key TEXT NOT NULL UNIQUE,
      owner_type TEXT NOT NULL CHECK (owner_type IN ('routine', 'event', 'document', 'plan', 'training_session')),
      owner_id INTEGER NOT NULL,
      role TEXT NOT NULL DEFAULT 'attachment',
      title TEXT NOT NULL,
      file_name TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      file_data BLOB NOT NULL DEFAULT X'',
      file_size INTEGER NOT NULL,
      created_at TEXT NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS legacy_assets (
      id INTEGER PRIMARY KEY,
      media_key TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      category TEXT NOT NULL,
      group_name TEXT NOT NULL DEFAULT '',
      relative_path TEXT NOT NULL UNIQUE,
      original_path TEXT NOT NULL,
      mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
      file_size INTEGER NOT NULL DEFAULT 0,
      notes TEXT NOT NULL DEFAULT ''
    )''',
    '''CREATE TABLE IF NOT EXISTS routine_legacy_assets (
      routine_id INTEGER NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
      legacy_asset_id INTEGER NOT NULL REFERENCES legacy_assets(id) ON DELETE CASCADE,
      role TEXT NOT NULL DEFAULT 'reference',
      PRIMARY KEY (routine_id, legacy_asset_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS event_legacy_assets (
      event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
      legacy_asset_id INTEGER NOT NULL REFERENCES legacy_assets(id) ON DELETE CASCADE,
      PRIMARY KEY (event_id, legacy_asset_id)
    )''',
  ];

  static const Map<String, Map<String, String>> _upgradeColumns = {
    'semesters': {
      'label': "TEXT NOT NULL DEFAULT ''",
      'start_date': 'TEXT',
      'end_date': 'TEXT',
      'is_current': 'INTEGER NOT NULL DEFAULT 0',
    },
    'members': {
      'person_id': 'INTEGER REFERENCES member_profiles(id)',
      'semester_id': 'INTEGER NOT NULL DEFAULT 0',
      'student_no': "TEXT NOT NULL DEFAULT ''",
      'name': "TEXT NOT NULL DEFAULT ''",
      'grade': "TEXT NOT NULL DEFAULT ''",
      'major': "TEXT NOT NULL DEFAULT ''",
      'position': "TEXT NOT NULL DEFAULT ''",
      'birthday': "TEXT NOT NULL DEFAULT ''",
      'contact': "TEXT NOT NULL DEFAULT ''",
      'notes': "TEXT NOT NULL DEFAULT ''",
      'active': 'INTEGER NOT NULL DEFAULT 1',
    },
    'attendance_sessions': {
      'semester_id': 'INTEGER NOT NULL DEFAULT 0',
      'session_date': "TEXT NOT NULL DEFAULT ''",
      'start_time': "TEXT NOT NULL DEFAULT '18:00'",
      'end_time': "TEXT NOT NULL DEFAULT '20:00'",
      'title': "TEXT NOT NULL DEFAULT '狮队训练'",
      'notes': "TEXT NOT NULL DEFAULT ''",
      'created_at': "TEXT NOT NULL DEFAULT ''",
      'updated_at': "TEXT NOT NULL DEFAULT ''",
    },
    'attendance_records': {
      'session_id': 'INTEGER NOT NULL DEFAULT 0',
      'member_id': 'INTEGER NOT NULL DEFAULT 0',
      'status': "TEXT NOT NULL DEFAULT 'pending'",
      'note': "TEXT NOT NULL DEFAULT ''",
    },
    'routines': {
      'title': "TEXT NOT NULL DEFAULT ''",
      'music': "TEXT NOT NULL DEFAULT ''",
      'movements': "TEXT NOT NULL DEFAULT ''",
      'notes': "TEXT NOT NULL DEFAULT ''",
      'created_at': "TEXT NOT NULL DEFAULT ''",
      'updated_at': "TEXT NOT NULL DEFAULT ''",
    },
    'events': {
      'title': "TEXT NOT NULL DEFAULT ''",
      'event_date': "TEXT NOT NULL DEFAULT ''",
      'location': "TEXT NOT NULL DEFAULT ''",
      'summary': "TEXT NOT NULL DEFAULT ''",
      'created_at': "TEXT NOT NULL DEFAULT ''",
      'updated_at': "TEXT NOT NULL DEFAULT ''",
    },
    'event_members': {
      'event_id': 'INTEGER NOT NULL DEFAULT 0',
      'member_id': 'INTEGER NOT NULL DEFAULT 0',
    },
    'documents': {
      'title': "TEXT NOT NULL DEFAULT ''",
      'document_type': "TEXT NOT NULL DEFAULT '通讯稿'",
      'document_date': "TEXT NOT NULL DEFAULT ''",
      'content': "TEXT NOT NULL DEFAULT ''",
      'legacy_asset_id': 'INTEGER',
      'created_at': "TEXT NOT NULL DEFAULT ''",
      'updated_at': "TEXT NOT NULL DEFAULT ''",
    },
    'training_plans': {
      'semester_id': 'INTEGER NOT NULL DEFAULT 0',
      'title': "TEXT NOT NULL DEFAULT ''",
      'content': "TEXT NOT NULL DEFAULT ''",
      'legacy_asset_id': 'INTEGER',
      'created_at': "TEXT NOT NULL DEFAULT ''",
      'updated_at': "TEXT NOT NULL DEFAULT ''",
    },
    'finance_entries': {
      'transaction_date': "TEXT NOT NULL DEFAULT ''",
      'entry_type': "TEXT NOT NULL DEFAULT 'expense'",
      'title': "TEXT NOT NULL DEFAULT ''",
      'amount_cents': 'INTEGER NOT NULL DEFAULT 0',
      'member_id': 'INTEGER',
      'notes': "TEXT NOT NULL DEFAULT ''",
      'created_at': "TEXT NOT NULL DEFAULT ''",
    },
    'media_assets': {
      'media_key': "TEXT NOT NULL DEFAULT ''",
      'owner_type': "TEXT NOT NULL DEFAULT 'routine'",
      'owner_id': 'INTEGER NOT NULL DEFAULT 0',
      'role': "TEXT NOT NULL DEFAULT 'attachment'",
      'title': "TEXT NOT NULL DEFAULT ''",
      'file_name': "TEXT NOT NULL DEFAULT ''",
      'mime_type': "TEXT NOT NULL DEFAULT 'application/octet-stream'",
      'file_data': "BLOB NOT NULL DEFAULT X''",
      'file_size': 'INTEGER NOT NULL DEFAULT 0',
      'created_at': "TEXT NOT NULL DEFAULT ''",
    },
    'legacy_assets': {
      'media_key': "TEXT NOT NULL DEFAULT ''",
      'title': "TEXT NOT NULL DEFAULT ''",
      'category': "TEXT NOT NULL DEFAULT 'archive'",
      'group_name': "TEXT NOT NULL DEFAULT ''",
      'relative_path': "TEXT NOT NULL DEFAULT ''",
      'original_path': "TEXT NOT NULL DEFAULT ''",
      'mime_type': "TEXT NOT NULL DEFAULT 'application/octet-stream'",
      'file_size': 'INTEGER NOT NULL DEFAULT 0',
      'notes': "TEXT NOT NULL DEFAULT ''",
    },
    'routine_legacy_assets': {
      'routine_id': 'INTEGER NOT NULL DEFAULT 0',
      'legacy_asset_id': 'INTEGER NOT NULL DEFAULT 0',
      'role': "TEXT NOT NULL DEFAULT 'reference'",
    },
    'event_legacy_assets': {
      'event_id': 'INTEGER NOT NULL DEFAULT 0',
      'legacy_asset_id': 'INTEGER NOT NULL DEFAULT 0',
    },
  };

  static const List<String> _createIndexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_members_semester ON members(semester_id, name)',
    'CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance_sessions(session_date DESC)',
    'CREATE INDEX IF NOT EXISTS idx_events_date ON events(event_date DESC)',
    'CREATE INDEX IF NOT EXISTS idx_finance_date ON finance_entries(transaction_date DESC)',
    'CREATE INDEX IF NOT EXISTS idx_legacy_category ON legacy_assets(category, group_name, title)',
    'CREATE INDEX IF NOT EXISTS idx_media_owner ON media_assets(owner_type, owner_id)',
  ];

  static void _ensureV2Columns(Database database) {
    for (final tableEntry in _upgradeColumns.entries) {
      final table = tableEntry.key;
      final columns = database.select('PRAGMA table_info($table)');
      final existing = columns.map((row) => row['name'].toString()).toSet();
      if (columns.isEmpty) {
        throw StateError('Could not create or locate the $table table.');
      }
      if (!existing.contains('id') &&
          table != 'event_members' &&
          table != 'routine_legacy_assets' &&
          table != 'event_legacy_assets') {
        throw StateError('Cannot safely migrate $table without its id column.');
      }
      for (final columnEntry in tableEntry.value.entries) {
        if (existing.contains(columnEntry.key)) continue;
        database.execute(
          'ALTER TABLE $table ADD COLUMN ${columnEntry.key} ${columnEntry.value}',
        );
      }
    }
  }

  /// Returns all semesters, with the current one first.
  List<Semester> getSemesters() {
    _ensureOpen();
    return _select('''
      SELECT id, label, start_date, end_date, is_current
      FROM semesters
      ORDER BY is_current DESC, start_date DESC, id DESC
    ''').map(Semester.fromMap).toList(growable: false);
  }

  Semester? getCurrentSemester() {
    _ensureOpen();
    final rows = _select('''
      SELECT id, label, start_date, end_date, is_current
      FROM semesters WHERE is_current = 1 ORDER BY id DESC LIMIT 1
    ''');
    return rows.isEmpty ? null : Semester.fromMap(rows.first);
  }

  int addSemester({
    required String label,
    String? startDate,
    String? endDate,
    bool isCurrent = false,
  }) {
    _ensureOpen();
    return _transaction(() {
      if (isCurrent) {
        _database.execute('UPDATE semesters SET is_current = 0');
      }
      _database.execute(
        '''INSERT INTO semesters (label, start_date, end_date, is_current)
           VALUES (?, ?, ?, ?)''',
        [label, startDate, endDate, isCurrent ? 1 : 0],
      );
      return _database.lastInsertRowId;
    });
  }

  void updateSemester(Semester semester) {
    _ensureOpen();
    _transaction(() {
      if (semester.isCurrent) {
        _database.execute('UPDATE semesters SET is_current = 0 WHERE id <> ?', [
          semester.id,
        ]);
      }
      _database.execute(
        '''UPDATE semesters
           SET label = ?, start_date = ?, end_date = ?, is_current = ?
           WHERE id = ?''',
        [
          semester.label,
          semester.startDate,
          semester.endDate,
          semester.isCurrent ? 1 : 0,
          semester.id,
        ],
      );
      _requireChangedRow('Semester', semester.id);
    });
  }

  void setCurrentSemester(int semesterId) {
    _ensureOpen();
    _transaction(() {
      _database.execute('UPDATE semesters SET is_current = 0');
      _database.execute('UPDATE semesters SET is_current = 1 WHERE id = ?', [
        semesterId,
      ]);
      _requireChangedRow('Semester', semesterId);
    });
  }

  void deleteSemester(int semesterId) {
    _ensureOpen();
    _database.execute('DELETE FROM semesters WHERE id = ?', [semesterId]);
  }

  List<Member> getMembers(int semesterId, {bool activeOnly = false}) {
    _ensureOpen();
    final activeClause = activeOnly ? ' AND active = 1' : '';
    return _select(
      '''
      SELECT id, person_id, semester_id, student_no, name, grade, major, position,
             birthday, contact, notes, active
      FROM members WHERE semester_id = ?$activeClause ORDER BY name, id
    ''',
      [semesterId],
    ).map(Member.fromMap).toList(growable: false);
  }

  Member? getMember(int memberId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, person_id, semester_id, student_no, name, grade, major, position,
             birthday, contact, notes, active
      FROM members WHERE id = ?
    ''',
      [memberId],
    );
    return rows.isEmpty ? null : Member.fromMap(rows.first);
  }

  List<PersonProfile> getPeople() {
    return getMemberProfiles();
  }

  /// Lists the global archive, including profiles without a current roster row.
  List<PersonProfile> getMemberProfiles() {
    _ensureOpen();
    return _select('''
      SELECT id, display_name, birthday, created_at, updated_at
      FROM member_profiles
      ORDER BY lower(display_name), id
    ''').map(PersonProfile.fromMap).toList(growable: false);
  }

  PersonProfile? getPerson(int personId) {
    return getMemberProfile(personId);
  }

  /// Returns one global profile by its stable ID.
  PersonProfile? getMemberProfile(int profileId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, display_name, birthday, created_at, updated_at
      FROM member_profiles WHERE id = ?
    ''',
      [profileId],
    );
    return rows.isEmpty ? null : PersonProfile.fromMap(rows.first);
  }

  /// Manually edits archive fields without changing term-specific member rows.
  void updatePersonProfile(PersonProfile profile) {
    _ensureOpen();
    _database.execute(
      '''UPDATE member_profiles
         SET display_name = ?, birthday = ?, updated_at = ? WHERE id = ?''',
      [profile.displayName.trim(), profile.birthday.trim(), _now(), profile.id],
    );
    _requireChangedRow('Person profile', profile.id);
  }

  /// Links a semester roster row to a selected global profile. When the row
  /// has a student number, all rows with the same normalized number are linked
  /// together so that identifier continues to resolve to one profile.
  void linkMemberToProfile({required int memberId, required int profileId}) {
    _ensureOpen();
    _transaction(() {
      _requireExists('member_profiles', profileId, 'Person profile');
      final rows = _database.select(
        'SELECT student_no FROM members WHERE id = ?',
        [memberId],
      );
      if (rows.isEmpty) throw ArgumentError('Member $memberId does not exist.');
      final key = _normalizedStudentNo(
        rows.first['student_no']?.toString() ?? '',
      );
      _database.execute('UPDATE members SET person_id = ? WHERE id = ?', [
        profileId,
        memberId,
      ]);
      if (key.isEmpty) return;

      _database.execute(
        '''
        INSERT INTO member_profile_student_ids
          (normalized_student_no, profile_id, created_at)
        VALUES (?, ?, ?)
        ON CONFLICT(normalized_student_no) DO UPDATE SET
          profile_id = excluded.profile_id
      ''',
        [key, profileId, _now()],
      );
      final matchingRows = _database.select(
        'SELECT id, student_no FROM members',
      );
      for (final matching in matchingRows) {
        if (_normalizedStudentNo(matching['student_no']?.toString() ?? '') ==
            key) {
          _database.execute('UPDATE members SET person_id = ? WHERE id = ?', [
            profileId,
            matching['id'],
          ]);
        }
      }
    });
  }

  /// Returns every semester snapshot that belongs to one long-term profile.
  List<Member> getMemberSemesterHistory(Member member) {
    return getMemberProfileHistory(member.personId);
  }

  /// Returns all term-specific roster records for one global profile.
  List<Member> getMemberProfileHistory(int profileId) {
    _ensureOpen();
    return _select(
      '''
      SELECT id, person_id, semester_id, student_no, name, grade, major, position,
             birthday, contact, notes, active
      FROM members
      WHERE person_id = ?
      ORDER BY
        (SELECT start_date FROM semesters WHERE semesters.id = members.semester_id),
        semester_id, id
    ''',
      [profileId],
    ).map(Member.fromMap).toList(growable: false);
  }

  /// Returns distinct historical events attended by any term row in a profile.
  List<EventModel> getProfileEventHistory(int profileId) {
    _ensureOpen();
    return _select(
      '''
      SELECT DISTINCT e.id, e.title, e.event_date, e.location, e.summary,
             e.semester_id, e.recurring_activity_id, e.event_type,
             e.created_at, e.updated_at
      FROM events AS e
      JOIN event_members AS em ON em.event_id = e.id
      JOIN members AS m ON m.id = em.member_id
      WHERE m.person_id = ?
      ORDER BY e.event_date DESC, e.id DESC
    ''',
      [profileId],
    ).map(EventModel.fromMap).toList(growable: false);
  }

  int _createPerson(String name, String birthday, String now) {
    _database.execute(
      '''INSERT INTO member_profiles (display_name, birthday, created_at, updated_at)
         VALUES (?, ?, ?, ?)''',
      [name.trim(), birthday.trim(), now, now],
    );
    return _database.lastInsertRowId;
  }

  int _resolveProfileForMember({
    required int? selectedProfileId,
    required String studentNo,
    required String name,
    required String birthday,
    required String now,
  }) {
    final key = _normalizedStudentNo(studentNo);
    if (selectedProfileId != null) {
      _requireExists('member_profiles', selectedProfileId, 'Person profile');
      if (key.isNotEmpty) {
        final mapped = _database.select(
          'SELECT profile_id FROM member_profile_student_ids WHERE normalized_student_no = ?',
          [key],
        );
        if (mapped.isNotEmpty &&
            (mapped.first['profile_id'] as num).toInt() != selectedProfileId) {
          throw ArgumentError(
            'Student number $studentNo is already linked to another profile.',
          );
        }
        _database.execute(
          '''
          INSERT OR IGNORE INTO member_profile_student_ids
            (normalized_student_no, profile_id, created_at)
          VALUES (?, ?, ?)
        ''',
          [key, selectedProfileId, now],
        );
      }
      return selectedProfileId;
    }

    if (key.isNotEmpty) {
      final mapped = _database.select(
        'SELECT profile_id FROM member_profile_student_ids WHERE normalized_student_no = ?',
        [key],
      );
      if (mapped.isNotEmpty) return (mapped.first['profile_id'] as num).toInt();
    }

    final profileId = _createPerson(name, birthday, now);
    if (key.isNotEmpty) {
      _database.execute(
        '''
        INSERT INTO member_profile_student_ids
          (normalized_student_no, profile_id, created_at)
        VALUES (?, ?, ?)
      ''',
        [key, profileId, now],
      );
    }
    return profileId;
  }

  int addMember({
    required int semesterId,
    int? personId,
    required String name,
    String studentNo = '',
    String grade = '',
    String major = '',
    String position = '',
    String birthday = '',
    String contact = '',
    String notes = '',
    bool active = true,
  }) {
    _ensureOpen();
    return _transaction(() {
      final now = _now();
      final resolvedPersonId = _resolveProfileForMember(
        selectedProfileId: personId,
        studentNo: studentNo,
        name: name,
        birthday: birthday,
        now: now,
      );
      _database.execute(
        '''INSERT INTO members
           (semester_id, person_id, student_no, name, grade, major, position,
            birthday, contact, notes, active)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          semesterId,
          resolvedPersonId,
          studentNo,
          name,
          grade,
          major,
          position,
          birthday,
          contact,
          notes,
          active ? 1 : 0,
        ],
      );
      return _database.lastInsertRowId;
    });
  }

  void updateMember(Member member) {
    _ensureOpen();
    _transaction(() {
      final now = _now();
      _requireExists('member_profiles', member.personId, 'Person profile');
      _database.execute(
        '''UPDATE members SET semester_id = ?, person_id = ?, student_no = ?,
           name = ?, grade = ?, major = ?, position = ?, birthday = ?,
           contact = COALESCE(?, contact),
           notes = ?, active = ? WHERE id = ?''',
        [
          member.semesterId,
          member.personId,
          member.studentNo,
          member.name,
          member.grade,
          member.major,
          member.position,
          member.birthday,
          member.contact,
          member.notes,
          member.active ? 1 : 0,
          member.id,
        ],
      );
      _requireChangedRow('Member', member.id);
      final key = _normalizedStudentNo(member.studentNo);
      if (key.isNotEmpty) {
        final mapped = _database.select(
          'SELECT profile_id FROM member_profile_student_ids WHERE normalized_student_no = ?',
          [key],
        );
        if (mapped.isNotEmpty &&
            (mapped.first['profile_id'] as num).toInt() != member.personId) {
          throw ArgumentError(
            'Student number ${member.studentNo} is already linked to another profile.',
          );
        }
        _database.execute(
          '''
          INSERT OR IGNORE INTO member_profile_student_ids
            (normalized_student_no, profile_id, created_at)
          VALUES (?, ?, ?)
        ''',
          [key, member.personId, now],
        );
      }
    });
  }

  void deleteMember(int memberId) {
    _ensureOpen();
    _database.execute('DELETE FROM members WHERE id = ?', [memberId]);
  }

  /// Removes a semester snapshot from the active roster without erasing the
  /// long-term profile, attendance records, or event history.
  void deactivateMember(int memberId) {
    _ensureOpen();
    _database.execute('UPDATE members SET active = 0 WHERE id = ?', [memberId]);
    _requireChangedRow('Member', memberId);
  }

  /// Copies roster snapshots into another semester while retaining the same
  /// long-term person IDs. Existing people in the destination are left intact.
  int copyMemberRoster({
    required int fromSemesterId,
    required int toSemesterId,
  }) {
    _ensureOpen();
    if (fromSemesterId == toSemesterId) return 0;
    return _transaction(() {
      _requireExists('semesters', fromSemesterId, 'Source semester');
      _requireExists('semesters', toSemesterId, 'Destination semester');
      _database.execute(
        '''
        INSERT OR IGNORE INTO members
          (semester_id, person_id, student_no, name, grade, major, position,
           birthday, contact, notes, active)
        SELECT ?, person_id, student_no, name, grade, major, position,
               birthday, contact, notes, active
        FROM members WHERE semester_id = ?
      ''',
        [toSemesterId, fromSemesterId],
      );
      return _changedRows;
    });
  }

  List<AttendanceSession> getAttendanceSessions(
    int semesterId, {
    String? fromDate,
    String? throughDate,
  }) {
    _ensureOpen();
    final clauses = <String>['semester_id = ?'];
    final values = <Object?>[semesterId];
    if (fromDate != null) {
      clauses.add('session_date >= ?');
      values.add(fromDate);
    }
    if (throughDate != null) {
      clauses.add('session_date <= ?');
      values.add(throughDate);
    }
    return _select('''
      SELECT id, semester_id, session_date, start_time, end_time, title, notes,
             created_at, updated_at
      FROM attendance_sessions
      WHERE ${clauses.join(' AND ')}
      ORDER BY session_date DESC, start_time DESC, id DESC
    ''', values).map(AttendanceSession.fromMap).toList(growable: false);
  }

  AttendanceSession? getAttendanceSession(int sessionId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, semester_id, session_date, start_time, end_time, title, notes,
             created_at, updated_at
      FROM attendance_sessions WHERE id = ?
    ''',
      [sessionId],
    );
    return rows.isEmpty ? null : AttendanceSession.fromMap(rows.first);
  }

  int addAttendanceSession({
    required int semesterId,
    required String sessionDate,
    String startTime = '18:00',
    String endTime = '20:00',
    String title = '狮队训练',
    String notes = '',
    bool initializePendingRecords = true,
  }) {
    _ensureOpen();
    final now = _now();
    return _transaction(() {
      _database.execute(
        '''INSERT INTO attendance_sessions
          (semester_id, session_date, start_time, end_time, title, notes, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        [semesterId, sessionDate, startTime, endTime, title, notes, now, now],
      );
      final sessionId = _database.lastInsertRowId;
      if (initializePendingRecords) {
        _database.execute(
          '''
          INSERT OR IGNORE INTO attendance_records (session_id, member_id, status, note)
          SELECT ?, id, 'pending', '' FROM members
          WHERE semester_id = ? AND active = 1
        ''',
          [sessionId, semesterId],
        );
      }
      return sessionId;
    });
  }

  void updateAttendanceSession(AttendanceSession session) {
    _ensureOpen();
    _database.execute(
      '''UPDATE attendance_sessions
         SET semester_id = ?, session_date = ?, start_time = ?, end_time = ?,
             title = ?, notes = ?, updated_at = ?
         WHERE id = ?''',
      [
        session.semesterId,
        session.sessionDate,
        session.startTime,
        session.endTime,
        session.title,
        session.notes,
        _now(),
        session.id,
      ],
    );
    _requireChangedRow('Attendance session', session.id);
  }

  void deleteAttendanceSession(int sessionId) {
    _ensureOpen();
    _database.execute('DELETE FROM attendance_sessions WHERE id = ?', [
      sessionId,
    ]);
  }

  List<AttendanceRecord> getAttendanceRecords(int sessionId) {
    _ensureOpen();
    return _select(
      '''
      SELECT ar.id, ar.session_id, ar.member_id, ar.status, ar.note,
             m.name AS member_name
      FROM attendance_records AS ar
      JOIN members AS m ON m.id = ar.member_id
      WHERE ar.session_id = ?
      ORDER BY m.name, m.id
    ''',
      [sessionId],
    ).map(AttendanceRecord.fromMap).toList(growable: false);
  }

  void saveAttendanceRecord({
    required int sessionId,
    required int memberId,
    required AttendanceStatus status,
    String note = '',
  }) {
    _ensureOpen();
    final matchingRows = _database.select(
      '''
      SELECT 1 AS found
      FROM attendance_sessions AS s
      JOIN members AS m ON m.semester_id = s.semester_id
      WHERE s.id = ? AND m.id = ?
      LIMIT 1
    ''',
      [sessionId, memberId],
    );
    if (matchingRows.isEmpty) {
      throw ArgumentError(
        'The member does not belong to this session semester.',
      );
    }
    _database.execute(
      '''
      INSERT INTO attendance_records (session_id, member_id, status, note)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(session_id, member_id)
      DO UPDATE SET status = excluded.status, note = excluded.note
    ''',
      [sessionId, memberId, status.sqliteValue, note],
    );
  }

  void deleteAttendanceRecord(int sessionId, int memberId) {
    _ensureOpen();
    _database.execute(
      'DELETE FROM attendance_records WHERE session_id = ? AND member_id = ?',
      [sessionId, memberId],
    );
  }

  List<RecurringActivityModel> getRecurringActivities({
    String? activityType,
    bool activeOnly = false,
  }) {
    _ensureOpen();
    final clauses = <String>[];
    final values = <Object?>[];
    if (activityType != null) {
      clauses.add('activity_type = ?');
      values.add(activityType);
    }
    if (activeOnly) clauses.add('active = 1');
    final whereClause = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _select('''
      SELECT id, title, activity_type, description, active, created_at, updated_at
      FROM recurring_activities $whereClause
      ORDER BY activity_type, title, id
    ''', values).map(RecurringActivityModel.fromMap).toList(growable: false);
  }

  RecurringActivityModel? getRecurringActivity(int activityId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, title, activity_type, description, active, created_at, updated_at
      FROM recurring_activities WHERE id = ?
    ''',
      [activityId],
    );
    return rows.isEmpty ? null : RecurringActivityModel.fromMap(rows.first);
  }

  int addRecurringActivity({
    required String title,
    required String activityType,
    String description = '',
    bool active = true,
  }) {
    _ensureOpen();
    final now = _now();
    _database.execute(
      '''INSERT INTO recurring_activities
         (title, activity_type, description, active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [
        title.trim(),
        _normalizeActivityType(activityType),
        description,
        active ? 1 : 0,
        now,
        now,
      ],
    );
    return _database.lastInsertRowId;
  }

  void updateRecurringActivity(RecurringActivityModel activity) {
    _ensureOpen();
    _database.execute(
      '''UPDATE recurring_activities
         SET title = ?, activity_type = ?, description = ?, active = ?, updated_at = ?
         WHERE id = ?''',
      [
        activity.title.trim(),
        _normalizeActivityType(activity.activityType),
        activity.description,
        activity.active ? 1 : 0,
        _now(),
        activity.id,
      ],
    );
    _requireChangedRow('Recurring activity', activity.id);
  }

  void deleteRecurringActivity(int activityId) {
    _ensureOpen();
    _database.execute('DELETE FROM recurring_activities WHERE id = ?', [
      activityId,
    ]);
  }

  static String _normalizeActivityType(String value) =>
      value.trim().isEmpty ? 'other' : value.trim();

  List<EventModel> getEvents({
    String? fromDate,
    String? throughDate,
    int? semesterId,
    String? eventType,
  }) {
    _ensureOpen();
    final clauses = <String>[];
    final values = <Object?>[];
    if (fromDate != null) {
      clauses.add('event_date >= ?');
      values.add(fromDate);
    }
    if (throughDate != null) {
      clauses.add('event_date <= ?');
      values.add(throughDate);
    }
    if (semesterId != null) {
      clauses.add('semester_id = ?');
      values.add(semesterId);
    }
    if (eventType != null) {
      clauses.add('event_type = ?');
      values.add(eventType);
    }
    final whereClause = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _select('''
      SELECT id, title, event_date, location, summary, semester_id,
             recurring_activity_id, event_type, created_at, updated_at
      FROM events $whereClause ORDER BY event_date DESC, id DESC
    ''', values).map(EventModel.fromMap).toList(growable: false);
  }

  /// Groups events by their stored semester (null means legacy/unknown) and
  /// event type, preserving distinct event records and their order.
  Map<int?, Map<String, List<EventModel>>> getEventsGroupedBySemesterAndType() {
    final grouped = <int?, Map<String, List<EventModel>>>{};
    for (final event in getEvents()) {
      final semesterGroup = grouped.putIfAbsent(
        event.semesterId,
        () => <String, List<EventModel>>{},
      );
      final type = event.eventType?.trim().isNotEmpty == true
          ? event.eventType!.trim()
          : 'other';
      semesterGroup.putIfAbsent(type, () => <EventModel>[]).add(event);
    }
    return grouped;
  }

  /// Returns distinct events attended by any of the supplied semester rows.
  List<EventModel> getEventsForMemberIds(Iterable<int> memberIds) {
    _ensureOpen();
    final ids = memberIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    return _select(
      '''
      SELECT DISTINCT e.id, e.title, e.event_date, e.location, e.summary,
             e.semester_id, e.recurring_activity_id, e.event_type,
             e.created_at, e.updated_at
      FROM events AS e
      JOIN event_members AS em ON em.event_id = e.id
      WHERE em.member_id IN ($placeholders)
      ORDER BY e.event_date DESC, e.id DESC
    ''',
      ids.map<Object?>((id) => id).toList(growable: false),
    ).map(EventModel.fromMap).toList(growable: false);
  }

  EventModel? getEvent(int eventId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, title, event_date, location, summary, semester_id,
             recurring_activity_id, event_type, created_at, updated_at
      FROM events WHERE id = ?
    ''',
      [eventId],
    );
    return rows.isEmpty ? null : EventModel.fromMap(rows.first);
  }

  int addEvent({
    required String title,
    String eventDate = '',
    String location = '',
    String summary = '',
    int? semesterId,
    int? recurringActivityId,
    String? eventType,
  }) {
    _ensureOpen();
    final now = _now();
    final resolvedEventType = eventType?.trim().isNotEmpty == true
        ? eventType!.trim()
        : _activityTypeFor(recurringActivityId) ?? 'other';
    _database.execute(
      '''INSERT INTO events
         (title, event_date, location, summary, semester_id,
          recurring_activity_id, event_type, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        title,
        eventDate,
        location,
        summary,
        semesterId,
        recurringActivityId,
        resolvedEventType,
        now,
        now,
      ],
    );
    return _database.lastInsertRowId;
  }

  void updateEvent(EventModel event) {
    _ensureOpen();
    final resolvedEventType =
        event.eventType ??
        (event.recurringActivityId == null
            ? null
            : _activityTypeFor(event.recurringActivityId));
    _database.execute(
      '''UPDATE events
         SET title = ?, event_date = ?, location = ?, summary = ?,
             semester_id = COALESCE(?, semester_id),
             recurring_activity_id = COALESCE(?, recurring_activity_id),
             event_type = COALESCE(?, event_type), updated_at = ?
         WHERE id = ?''',
      [
        event.title,
        event.eventDate,
        event.location,
        event.summary,
        event.semesterId,
        event.recurringActivityId,
        resolvedEventType,
        _now(),
        event.id,
      ],
    );
    _requireChangedRow('Event', event.id);
  }

  /// Explicitly sets or clears an event's semester and recurring-activity
  /// classification. A null semester keeps the term unknown/unassigned.
  void updateEventClassification({
    required int eventId,
    int? semesterId,
    int? recurringActivityId,
    String? eventType,
  }) {
    _ensureOpen();
    final resolvedEventType = eventType == null
        ? _activityTypeFor(recurringActivityId) ?? 'other'
        : _normalizeActivityType(eventType);
    _database.execute(
      '''UPDATE events
         SET semester_id = ?, recurring_activity_id = ?, event_type = ?,
             updated_at = ? WHERE id = ?''',
      [semesterId, recurringActivityId, resolvedEventType, _now(), eventId],
    );
    _requireChangedRow('Event', eventId);
  }

  void linkEventToRecurringActivity({
    required int eventId,
    required int? recurringActivityId,
  }) {
    _ensureOpen();
    final activityType = _activityTypeFor(recurringActivityId);
    _database.execute(
      '''UPDATE events
         SET recurring_activity_id = ?,
             event_type = COALESCE(?, event_type), updated_at = ?
         WHERE id = ?''',
      [recurringActivityId, activityType, _now(), eventId],
    );
    _requireChangedRow('Event', eventId);
  }

  String? _activityTypeFor(int? recurringActivityId) {
    if (recurringActivityId == null) return null;
    final rows = _database.select(
      'SELECT activity_type FROM recurring_activities WHERE id = ?',
      [recurringActivityId],
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(recurringActivityId, 'recurringActivityId');
    }
    return rows.first['activity_type']?.toString();
  }

  void deleteEvent(int eventId) {
    _ensureOpen();
    _database.execute('DELETE FROM events WHERE id = ?', [eventId]);
  }

  List<Member> getEventParticipants(int eventId) {
    _ensureOpen();
    return _select(
      '''
      SELECT m.id, m.person_id, m.semester_id, m.student_no, m.name, m.grade,
             m.major, m.position, m.birthday, m.contact, m.notes, m.active
      FROM event_members AS em
      JOIN members AS m ON m.id = em.member_id
      WHERE em.event_id = ? ORDER BY m.name, m.id
    ''',
      [eventId],
    ).map(Member.fromMap).toList(growable: false);
  }

  void addEventParticipant(int eventId, int memberId) {
    _ensureOpen();
    _database.execute(
      'INSERT OR IGNORE INTO event_members (event_id, member_id) VALUES (?, ?)',
      [eventId, memberId],
    );
  }

  void removeEventParticipant(int eventId, int memberId) {
    _ensureOpen();
    _database.execute(
      'DELETE FROM event_members WHERE event_id = ? AND member_id = ?',
      [eventId, memberId],
    );
  }

  void replaceEventParticipants(int eventId, Iterable<int> memberIds) {
    _ensureOpen();
    final ids = memberIds.toSet();
    _transaction(() {
      _requireExists('events', eventId, 'Event');
      _database.execute('DELETE FROM event_members WHERE event_id = ?', [
        eventId,
      ]);
      for (final memberId in ids) {
        _database.execute(
          'INSERT INTO event_members (event_id, member_id) VALUES (?, ?)',
          [eventId, memberId],
        );
      }
    });
  }

  List<InventoryItemModel> getInventoryItems({String? search}) {
    _ensureOpen();
    final term = search?.trim() ?? '';
    final rows = term.isEmpty
        ? _select('''
            SELECT id, name, category, unit, current_quantity, location,
                   condition, notes,
                   created_at, updated_at
            FROM inventory_items ORDER BY name, id
          ''')
        : _select(
            '''
            SELECT id, name, category, unit, current_quantity, location,
                   condition, notes,
                   created_at, updated_at
            FROM inventory_items
            WHERE name LIKE ? OR category LIKE ? OR unit LIKE ?
               OR location LIKE ? OR notes LIKE ?
            ORDER BY name, id
          ''',
            ['%$term%', '%$term%', '%$term%', '%$term%', '%$term%'],
          );
    return rows.map(InventoryItemModel.fromMap).toList(growable: false);
  }

  InventoryItemModel? getInventoryItem(int itemId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, name, category, unit, current_quantity, location, condition,
             notes,
             created_at, updated_at
      FROM inventory_items WHERE id = ?
    ''',
      [itemId],
    );
    return rows.isEmpty ? null : InventoryItemModel.fromMap(rows.first);
  }

  int addInventoryItem({
    required String name,
    String category = '',
    String unit = '',
    int currentQuantity = 0,
    String location = '',
    String condition = '',
    String notes = '',
  }) {
    _ensureOpen();
    _validateInventoryCount(currentQuantity);
    final now = _now();
    return _transaction(() {
      _database.execute(
        '''INSERT INTO inventory_items
           (name, category, unit, current_quantity, location, condition,
            notes, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          name.trim(),
          category,
          unit,
          currentQuantity,
          location,
          condition,
          notes,
          now,
          now,
        ],
      );
      final itemId = _database.lastInsertRowId;
      if (currentQuantity > 0) {
        _insertInventoryMovement(
          itemId: itemId,
          movementType: InventoryMovementType.adjustment,
          quantityDelta: currentQuantity,
          movementDate: _today(),
          notes: 'Initial count',
          createdAt: now,
        );
      }
      return itemId;
    });
  }

  /// Updates item details and records a signed adjustment when the current
  /// quantity changes. The explicit adjustment note can be used for audits.
  void updateInventoryItem(
    InventoryItemModel item, {
    String adjustmentNotes = 'Manual count adjustment',
  }) {
    _ensureOpen();
    _validateInventoryCount(item.currentQuantity);
    _transaction(() {
      final rows = _database.select(
        'SELECT current_quantity FROM inventory_items WHERE id = ?',
        [item.id],
      );
      if (rows.isEmpty) {
        throw ArgumentError('Inventory item ${item.id} does not exist.');
      }
      final oldQuantity = (rows.first['current_quantity'] as num).toInt();
      final delta = item.currentQuantity - oldQuantity;
      _database.execute(
        '''UPDATE inventory_items
           SET name = ?, category = ?, unit = ?, current_quantity = ?,
               location = ?, condition = ?, notes = ?, updated_at = ?
           WHERE id = ?''',
        [
          item.name.trim(),
          item.category,
          item.unit,
          item.currentQuantity,
          item.location,
          item.condition,
          item.notes,
          _now(),
          item.id,
        ],
      );
      _requireChangedRow('Inventory item', item.id);
      if (delta != 0) {
        _insertInventoryMovement(
          itemId: item.id,
          movementType: InventoryMovementType.adjustment,
          quantityDelta: delta,
          movementDate: _today(),
          notes: adjustmentNotes,
          createdAt: _now(),
        );
      }
    });
  }

  void deleteInventoryItem(int itemId) {
    _ensureOpen();
    _database.execute('DELETE FROM inventory_items WHERE id = ?', [itemId]);
  }

  List<InventoryMovementModel> getInventoryMovements({
    int? itemId,
    String? fromDate,
    String? throughDate,
  }) {
    _ensureOpen();
    final clauses = <String>[];
    final values = <Object?>[];
    if (itemId != null) {
      clauses.add('item_id = ?');
      values.add(itemId);
    }
    if (fromDate != null) {
      clauses.add('movement_date >= ?');
      values.add(fromDate);
    }
    if (throughDate != null) {
      clauses.add('movement_date <= ?');
      values.add(throughDate);
    }
    final whereClause = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _select('''
      SELECT id, item_id, movement_type, quantity_delta, movement_date,
             notes, created_at
      FROM inventory_movements $whereClause
      ORDER BY movement_date DESC, id DESC
    ''', values).map(InventoryMovementModel.fromMap).toList(growable: false);
  }

  int addInventoryMovement({
    required int itemId,
    required InventoryMovementType movementType,
    required int quantity,
    String? movementDate,
    String notes = '',
  }) {
    _ensureOpen();
    final delta = _inventoryQuantityDelta(movementType, quantity);
    return _transaction(() {
      final current = _currentInventoryCount(itemId);
      final next = current + delta;
      _validateInventoryCount(next);
      final now = _now();
      _database.execute(
        'UPDATE inventory_items SET current_quantity = ?, updated_at = ? WHERE id = ?',
        [next, now, itemId],
      );
      _requireChangedRow('Inventory item', itemId);
      _insertInventoryMovement(
        itemId: itemId,
        movementType: movementType,
        quantityDelta: delta,
        movementDate: movementDate ?? _today(),
        notes: notes,
        createdAt: now,
      );
      return _database.lastInsertRowId;
    });
  }

  void updateInventoryMovement(InventoryMovementModel movement) {
    _ensureOpen();
    _validateStoredInventoryDelta(
      movement.movementType,
      movement.quantityDelta,
    );
    _transaction(() {
      final rows = _database.select(
        'SELECT item_id, movement_type, quantity_delta FROM inventory_movements WHERE id = ?',
        [movement.id],
      );
      if (rows.isEmpty) {
        throw ArgumentError(
          'Inventory movement ${movement.id} does not exist.',
        );
      }
      final oldItemId = (rows.first['item_id'] as num).toInt();
      final oldDelta = (rows.first['quantity_delta'] as num).toInt();
      if (oldItemId == movement.itemId) {
        final next =
            _currentInventoryCount(oldItemId) -
            oldDelta +
            movement.quantityDelta;
        _validateInventoryCount(next);
        _database.execute(
          'UPDATE inventory_items SET current_quantity = ?, updated_at = ? WHERE id = ?',
          [next, _now(), oldItemId],
        );
      } else {
        final oldNext = _currentInventoryCount(oldItemId) - oldDelta;
        final newNext =
            _currentInventoryCount(movement.itemId) + movement.quantityDelta;
        _validateInventoryCount(oldNext);
        _validateInventoryCount(newNext);
        _database.execute(
          'UPDATE inventory_items SET current_quantity = ?, updated_at = ? WHERE id = ?',
          [oldNext, _now(), oldItemId],
        );
        _database.execute(
          'UPDATE inventory_items SET current_quantity = ?, updated_at = ? WHERE id = ?',
          [newNext, _now(), movement.itemId],
        );
        _requireChangedRow('Inventory item', movement.itemId);
      }
      _database.execute(
        '''UPDATE inventory_movements
           SET item_id = ?, movement_type = ?, quantity_delta = ?,
               movement_date = ?, notes = ? WHERE id = ?''',
        [
          movement.itemId,
          movement.movementType.sqliteValue,
          movement.quantityDelta,
          movement.movementDate,
          movement.notes,
          movement.id,
        ],
      );
    });
  }

  void deleteInventoryMovement(int movementId) {
    _ensureOpen();
    _transaction(() {
      final rows = _database.select(
        'SELECT item_id, quantity_delta FROM inventory_movements WHERE id = ?',
        [movementId],
      );
      if (rows.isEmpty) return;
      final itemId = (rows.first['item_id'] as num).toInt();
      final delta = (rows.first['quantity_delta'] as num).toInt();
      final next = _currentInventoryCount(itemId) - delta;
      _validateInventoryCount(next);
      _database.execute(
        'UPDATE inventory_items SET current_quantity = ?, updated_at = ? WHERE id = ?',
        [next, _now(), itemId],
      );
      _database.execute('DELETE FROM inventory_movements WHERE id = ?', [
        movementId,
      ]);
    });
  }

  int _currentInventoryCount(int itemId) {
    final rows = _database.select(
      'SELECT current_quantity FROM inventory_items WHERE id = ?',
      [itemId],
    );
    if (rows.isEmpty) {
      throw ArgumentError('Inventory item $itemId does not exist.');
    }
    return (rows.first['current_quantity'] as num).toInt();
  }

  void _insertInventoryMovement({
    required int itemId,
    required InventoryMovementType movementType,
    required int quantityDelta,
    required String movementDate,
    required String notes,
    required String createdAt,
  }) {
    _validateStoredInventoryDelta(movementType, quantityDelta);
    _database.execute(
      '''INSERT INTO inventory_movements
         (item_id, movement_type, quantity_delta, movement_date, notes, created_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [
        itemId,
        movementType.sqliteValue,
        quantityDelta,
        movementDate,
        notes,
        createdAt,
      ],
    );
  }

  static int _inventoryQuantityDelta(
    InventoryMovementType movementType,
    int quantity,
  ) {
    if (movementType == InventoryMovementType.adjustment) {
      if (quantity == 0) {
        throw ArgumentError.value(quantity, 'quantity', 'Must not be zero.');
      }
      return quantity;
    }
    if (quantity <= 0) {
      throw ArgumentError.value(quantity, 'quantity', 'Must be positive.');
    }
    return movementType.isOutbound ? -quantity : quantity;
  }

  static void _validateStoredInventoryDelta(
    InventoryMovementType movementType,
    int quantityDelta,
  ) {
    if (quantityDelta == 0 ||
        (movementType.isInbound && quantityDelta < 0) ||
        (movementType.isOutbound && quantityDelta > 0)) {
      throw ArgumentError.value(
        quantityDelta,
        'quantityDelta',
        'Quantity sign must match the movement type and cannot be zero.',
      );
    }
  }

  static void _validateInventoryCount(int value) {
    if (value < 0) {
      throw ArgumentError.value(
        value,
        'currentQuantity',
        'Must be nonnegative.',
      );
    }
  }

  static String _today() =>
      DateTime.now().toUtc().toIso8601String().substring(0, 10);

  List<RoutineModel> getRoutines() {
    _ensureOpen();
    return _select('''
      SELECT id, title, music, movements, notes, created_at, updated_at
      FROM routines ORDER BY title, id
    ''').map(RoutineModel.fromMap).toList(growable: false);
  }

  RoutineModel? getRoutine(int routineId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, title, music, movements, notes, created_at, updated_at
      FROM routines WHERE id = ?
    ''',
      [routineId],
    );
    return rows.isEmpty ? null : RoutineModel.fromMap(rows.first);
  }

  int addRoutine({
    required String title,
    String music = '',
    String movements = '',
    String notes = '',
  }) {
    _ensureOpen();
    final now = _now();
    _database.execute(
      '''INSERT INTO routines
         (title, music, movements, notes, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [title, music, movements, notes, now, now],
    );
    return _database.lastInsertRowId;
  }

  void updateRoutine(RoutineModel routine) {
    _ensureOpen();
    _database.execute(
      '''UPDATE routines
         SET title = ?, music = ?, movements = ?, notes = ?, updated_at = ?
         WHERE id = ?''',
      [
        routine.title,
        routine.music,
        routine.movements,
        routine.notes,
        _now(),
        routine.id,
      ],
    );
    _requireChangedRow('Routine', routine.id);
  }

  void deleteRoutine(int routineId) {
    _ensureOpen();
    _database.execute('DELETE FROM routines WHERE id = ?', [routineId]);
  }

  List<DocumentModel> getDocuments({String? documentType}) {
    _ensureOpen();
    final rows = documentType == null
        ? _select('''
            SELECT id, title, document_type, document_date, content,
                   legacy_asset_id, created_at, updated_at
            FROM documents ORDER BY document_date DESC, id DESC
          ''')
        : _select(
            '''
            SELECT id, title, document_type, document_date, content,
                   legacy_asset_id, created_at, updated_at
            FROM documents WHERE document_type = ?
            ORDER BY document_date DESC, id DESC
          ''',
            [documentType],
          );
    return rows.map(DocumentModel.fromMap).toList(growable: false);
  }

  DocumentModel? getDocument(int documentId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, title, document_type, document_date, content, legacy_asset_id,
             created_at, updated_at
      FROM documents WHERE id = ?
    ''',
      [documentId],
    );
    return rows.isEmpty ? null : DocumentModel.fromMap(rows.first);
  }

  int addDocument({
    required String title,
    String documentType = '通讯稿',
    String documentDate = '',
    String content = '',
    int? legacyAssetId,
  }) {
    _ensureOpen();
    final now = _now();
    _database.execute(
      '''INSERT INTO documents
         (title, document_type, document_date, content, legacy_asset_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [title, documentType, documentDate, content, legacyAssetId, now, now],
    );
    return _database.lastInsertRowId;
  }

  void updateDocument(DocumentModel document) {
    _ensureOpen();
    _database.execute(
      '''UPDATE documents
         SET title = ?, document_type = ?, document_date = ?, content = ?,
             legacy_asset_id = ?, updated_at = ?
         WHERE id = ?''',
      [
        document.title,
        document.documentType,
        document.documentDate,
        document.content,
        document.legacyAssetId,
        _now(),
        document.id,
      ],
    );
    _requireChangedRow('Document', document.id);
  }

  void deleteDocument(int documentId) {
    _ensureOpen();
    _database.execute('DELETE FROM documents WHERE id = ?', [documentId]);
  }

  List<TrainingPlanModel> getTrainingPlans(int semesterId) {
    _ensureOpen();
    return _select(
      '''
      SELECT id, semester_id, title, content, legacy_asset_id, created_at, updated_at
      FROM training_plans WHERE semester_id = ? ORDER BY created_at DESC, id DESC
    ''',
      [semesterId],
    ).map(TrainingPlanModel.fromMap).toList(growable: false);
  }

  TrainingPlanModel? getTrainingPlan(int planId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, semester_id, title, content, legacy_asset_id, created_at, updated_at
      FROM training_plans WHERE id = ?
    ''',
      [planId],
    );
    return rows.isEmpty ? null : TrainingPlanModel.fromMap(rows.first);
  }

  int addTrainingPlan({
    required int semesterId,
    required String title,
    String content = '',
    int? legacyAssetId,
  }) {
    _ensureOpen();
    final now = _now();
    _database.execute(
      '''INSERT INTO training_plans
         (semester_id, title, content, legacy_asset_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [semesterId, title, content, legacyAssetId, now, now],
    );
    return _database.lastInsertRowId;
  }

  void updateTrainingPlan(TrainingPlanModel plan) {
    _ensureOpen();
    _database.execute(
      '''UPDATE training_plans
         SET semester_id = ?, title = ?, content = ?, legacy_asset_id = ?, updated_at = ?
         WHERE id = ?''',
      [
        plan.semesterId,
        plan.title,
        plan.content,
        plan.legacyAssetId,
        _now(),
        plan.id,
      ],
    );
    _requireChangedRow('Training plan', plan.id);
  }

  void deleteTrainingPlan(int planId) {
    _ensureOpen();
    _database.execute('DELETE FROM training_plans WHERE id = ?', [planId]);
  }

  List<FinanceEntryModel> getFinanceEntries({
    String? fromDate,
    String? throughDate,
    FinanceEntryType? type,
  }) {
    _ensureOpen();
    final clauses = <String>[];
    final values = <Object?>[];
    if (fromDate != null) {
      clauses.add('transaction_date >= ?');
      values.add(fromDate);
    }
    if (throughDate != null) {
      clauses.add('transaction_date <= ?');
      values.add(throughDate);
    }
    if (type != null) {
      clauses.add('entry_type = ?');
      values.add(type.sqliteValue);
    }
    final whereClause = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _select('''
      SELECT id, transaction_date, entry_type, title, amount_cents, member_id,
             notes, created_at
      FROM finance_entries $whereClause
      ORDER BY transaction_date DESC, id DESC
    ''', values).map(FinanceEntryModel.fromMap).toList(growable: false);
  }

  FinanceEntryModel? getFinanceEntry(int entryId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, transaction_date, entry_type, title, amount_cents, member_id,
             notes, created_at
      FROM finance_entries WHERE id = ?
    ''',
      [entryId],
    );
    return rows.isEmpty ? null : FinanceEntryModel.fromMap(rows.first);
  }

  int addFinanceEntry({
    required String transactionDate,
    required FinanceEntryType entryType,
    required String title,
    required int amountCents,
    int? memberId,
    String notes = '',
  }) {
    _ensureOpen();
    if (amountCents < 0) throw ArgumentError.value(amountCents, 'amountCents');
    _database.execute(
      '''INSERT INTO finance_entries
         (transaction_date, entry_type, title, amount_cents, member_id, notes, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [
        transactionDate,
        entryType.sqliteValue,
        title,
        amountCents,
        memberId,
        notes,
        _now(),
      ],
    );
    return _database.lastInsertRowId;
  }

  void updateFinanceEntry(FinanceEntryModel entry) {
    _ensureOpen();
    if (entry.amountCents < 0) {
      throw ArgumentError.value(entry.amountCents, 'amountCents');
    }
    _database.execute(
      '''UPDATE finance_entries
         SET transaction_date = ?, entry_type = ?, title = ?, amount_cents = ?,
             member_id = ?, notes = ? WHERE id = ?''',
      [
        entry.transactionDate,
        entry.entryType.sqliteValue,
        entry.title,
        entry.amountCents,
        entry.memberId,
        entry.notes,
        entry.id,
      ],
    );
    _requireChangedRow('Finance entry', entry.id);
  }

  void deleteFinanceEntry(int entryId) {
    _ensureOpen();
    _database.execute('DELETE FROM finance_entries WHERE id = ?', [entryId]);
  }

  List<LegacyAssetModel> getLegacyAssets({
    String? category,
    String? groupName,
  }) {
    _ensureOpen();
    final clauses = <String>[];
    final values = <Object?>[];
    if (category != null) {
      clauses.add('category = ?');
      values.add(category);
    }
    if (groupName != null) {
      clauses.add('group_name = ?');
      values.add(groupName);
    }
    final whereClause = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _select('''
      SELECT id, media_key, title, category, group_name, relative_path,
             original_path, mime_type, file_size, notes
      FROM legacy_assets $whereClause
      ORDER BY category, group_name, title, id
    ''', values).map(LegacyAssetModel.fromMap).toList(growable: false);
  }

  LegacyAssetModel? getLegacyAsset(int assetId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, media_key, title, category, group_name, relative_path,
             original_path, mime_type, file_size, notes
      FROM legacy_assets WHERE id = ?
    ''',
      [assetId],
    );
    return rows.isEmpty ? null : LegacyAssetModel.fromMap(rows.first);
  }

  int addLegacyAsset({
    String? mediaKey,
    required String title,
    required String category,
    String groupName = '',
    required String relativePath,
    required String originalPath,
    String mimeType = 'application/octet-stream',
    int fileSize = 0,
    String notes = '',
  }) {
    _ensureOpen();
    final key = mediaKey ?? _newMediaKey();
    _validateMediaKey(key);
    _database.execute(
      '''
      INSERT INTO legacy_assets
        (media_key, title, category, group_name, relative_path, original_path,
         mime_type, file_size, notes)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        key,
        title,
        category,
        groupName,
        relativePath,
        originalPath,
        mimeType,
        fileSize,
        notes,
      ],
    );
    return _database.lastInsertRowId;
  }

  void updateLegacyAsset(LegacyAssetModel asset) {
    _ensureOpen();
    _validateMediaKey(asset.mediaKey);
    _database.execute(
      '''
      UPDATE legacy_assets
      SET media_key = ?, title = ?, category = ?, group_name = ?, relative_path = ?,
          original_path = ?, mime_type = ?, file_size = ?, notes = ?
      WHERE id = ?
    ''',
      [
        asset.mediaKey,
        asset.title,
        asset.category,
        asset.groupName,
        asset.relativePath,
        asset.originalPath,
        asset.mimeType,
        asset.fileSize,
        asset.notes,
        asset.id,
      ],
    );
    _requireChangedRow('Legacy asset', asset.id);
  }

  Future<void> deleteLegacyAsset(int assetId) async {
    _ensureOpen();
    final asset = getLegacyAsset(assetId);
    if (asset == null) return;
    _database.execute('DELETE FROM legacy_assets WHERE id = ?', [assetId]);
    _database.execute('DELETE FROM media_file_paths WHERE media_key = ?', [
      asset.mediaKey,
    ]);
    final mediaFile = _mediaFileForKey(asset.mediaKey);
    if (await mediaFile.exists()) await mediaFile.delete();
  }

  List<LegacyAssetModel> getRoutineLegacyAssets(int routineId) {
    _ensureOpen();
    return _select(
      '''
      SELECT la.id, la.media_key, la.title, la.category, la.group_name,
             la.relative_path, la.original_path, la.mime_type, la.file_size,
             la.notes
      FROM routine_legacy_assets AS link
      JOIN legacy_assets AS la ON la.id = link.legacy_asset_id
      WHERE link.routine_id = ? ORDER BY la.title, la.id
    ''',
      [routineId],
    ).map(LegacyAssetModel.fromMap).toList(growable: false);
  }

  void linkRoutineLegacyAsset({
    required int routineId,
    required int legacyAssetId,
    String role = 'reference',
  }) {
    _ensureOpen();
    _database.execute(
      '''
      INSERT INTO routine_legacy_assets (routine_id, legacy_asset_id, role)
      VALUES (?, ?, ?)
      ON CONFLICT(routine_id, legacy_asset_id) DO UPDATE SET role = excluded.role
    ''',
      [routineId, legacyAssetId, role],
    );
  }

  void unlinkRoutineLegacyAsset(int routineId, int legacyAssetId) {
    _ensureOpen();
    _database.execute(
      'DELETE FROM routine_legacy_assets WHERE routine_id = ? AND legacy_asset_id = ?',
      [routineId, legacyAssetId],
    );
  }

  List<LegacyAssetModel> getEventLegacyAssets(int eventId) {
    _ensureOpen();
    return _select(
      '''
      SELECT la.id, la.media_key, la.title, la.category, la.group_name,
             la.relative_path, la.original_path, la.mime_type, la.file_size,
             la.notes
      FROM event_legacy_assets AS link
      JOIN legacy_assets AS la ON la.id = link.legacy_asset_id
      WHERE link.event_id = ? ORDER BY la.title, la.id
    ''',
      [eventId],
    ).map(LegacyAssetModel.fromMap).toList(growable: false);
  }

  void linkEventLegacyAsset(int eventId, int legacyAssetId) {
    _ensureOpen();
    _database.execute(
      'INSERT OR IGNORE INTO event_legacy_assets (event_id, legacy_asset_id) VALUES (?, ?)',
      [eventId, legacyAssetId],
    );
  }

  void unlinkEventLegacyAsset(int eventId, int legacyAssetId) {
    _ensureOpen();
    _database.execute(
      'DELETE FROM event_legacy_assets WHERE event_id = ? AND legacy_asset_id = ?',
      [eventId, legacyAssetId],
    );
  }

  List<MediaAssetModel> getMediaAssets({String? ownerType, int? ownerId}) {
    _ensureOpen();
    final clauses = <String>[];
    final values = <Object?>[];
    if (ownerType != null) {
      clauses.add('owner_type = ?');
      values.add(ownerType);
    }
    if (ownerId != null) {
      clauses.add('owner_id = ?');
      values.add(ownerId);
    }
    final whereClause = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _select('''
      SELECT asset.id, asset.media_key, asset.owner_type, asset.owner_id,
             asset.role, asset.title, asset.file_name, asset.mime_type,
             asset.file_size, path.relative_path, asset.created_at
      FROM media_assets AS asset
      LEFT JOIN media_file_paths AS path ON path.media_key = asset.media_key
      $whereClause ORDER BY asset.created_at DESC, asset.id DESC
    ''', values).map(MediaAssetModel.fromMap).toList(growable: false);
  }

  /// Persists media ownership and its app-support-relative file path.
  ///
  /// Call after MediaStore has written the file. This method does not copy or
  /// read file content, and the SQLite `file_data` column remains empty.
  MediaAssetModel putMediaAssetMetadata({
    required String mediaKey,
    required String relativePath,
    required String ownerType,
    required int ownerId,
    String role = 'attachment',
    required String title,
    required String fileName,
    required String mimeType,
    required int fileSize,
  }) {
    _ensureOpen();
    _validateMediaKey(mediaKey);
    if (!const {
      'routine',
      'event',
      'document',
      'plan',
      'training_session',
    }.contains(ownerType)) {
      throw ArgumentError.value(ownerType, 'ownerType');
    }
    if (fileSize < 0) throw ArgumentError.value(fileSize, 'fileSize');
    _validateMediaRelativePath(mediaKey, relativePath);

    _transaction(() {
      final existing = _select(
        'SELECT created_at FROM media_assets WHERE media_key = ?',
        [mediaKey],
      );
      final createdAt = existing.isEmpty
          ? _now()
          : existing.first['created_at']?.toString() ?? _now();
      _database.execute(
        '''
        INSERT INTO media_assets
          (media_key, owner_type, owner_id, role, title, file_name, mime_type,
           file_size, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(media_key) DO UPDATE SET
          owner_type = excluded.owner_type,
          owner_id = excluded.owner_id,
          role = excluded.role,
          title = excluded.title,
          file_name = excluded.file_name,
          mime_type = excluded.mime_type,
          file_size = excluded.file_size
      ''',
        [
          mediaKey,
          ownerType,
          ownerId,
          role,
          title,
          fileName,
          mimeType,
          fileSize,
          createdAt,
        ],
      );
      _database.execute(
        '''
        INSERT INTO media_file_paths (media_key, relative_path, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(media_key) DO UPDATE SET
          relative_path = excluded.relative_path,
          updated_at = excluded.updated_at
      ''',
        [mediaKey, relativePath, _now()],
      );
    });

    final rows = _select(
      '''
      SELECT asset.id, asset.media_key, asset.owner_type, asset.owner_id,
             asset.role, asset.title, asset.file_name, asset.mime_type,
             asset.file_size, path.relative_path, asset.created_at
      FROM media_assets AS asset
      JOIN media_file_paths AS path ON path.media_key = asset.media_key
      WHERE asset.media_key = ?
    ''',
      [mediaKey],
    );
    return MediaAssetModel.fromMap(rows.single);
  }

  /// Convenience import from a raw file. New code should use MediaStore and
  /// then call [putMediaAssetMetadata] so the file is copied only once.
  Future<MediaAssetModel> putMediaAssetFile({
    String? mediaKey,
    required String ownerType,
    required int ownerId,
    String role = 'attachment',
    required String title,
    required String fileName,
    required String mimeType,
    required File sourceFile,
  }) async {
    _ensureOpen();
    if (!const {
      'routine',
      'event',
      'document',
      'plan',
      'training_session',
    }.contains(ownerType)) {
      throw ArgumentError.value(ownerType, 'ownerType');
    }
    if (!await sourceFile.exists()) {
      throw FileSystemException(
        'Media source file does not exist',
        sourceFile.path,
      );
    }
    final key = mediaKey ?? _newMediaKey();
    _validateMediaKey(key);
    final fileSize = await sourceFile.length();
    final replacement = await _replaceMediaFile(key, sourceFile);
    try {
      final result = putMediaAssetMetadata(
        mediaKey: key,
        relativePath: _relativeMediaPath(key),
        ownerType: ownerType,
        ownerId: ownerId,
        role: role,
        title: title,
        fileName: fileName,
        mimeType: mimeType,
        fileSize: fileSize,
      );
      await replacement.commit();
      return result;
    } catch (_) {
      await replacement.rollback();
      rethrow;
    }
  }

  Future<void> deleteMediaAsset(int mediaAssetId) async {
    _ensureOpen();
    final rows = _select('SELECT media_key FROM media_assets WHERE id = ?', [
      mediaAssetId,
    ]);
    if (rows.isEmpty) return;
    final key = rows.first['media_key'].toString();
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute('DELETE FROM media_assets WHERE id = ?', [
        mediaAssetId,
      ]);
      _database.execute('DELETE FROM media_file_paths WHERE media_key = ?', [
        key,
      ]);
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<File?> mediaFileForKey(String mediaKey) async {
    _ensureOpen();
    _validateMediaKey(mediaKey);
    final rows = _select(
      'SELECT relative_path FROM media_file_paths WHERE media_key = ?',
      [mediaKey],
    );
    if (rows.isEmpty) return null;
    final relativePath = rows.first['relative_path']?.toString() ?? '';
    _validateMediaRelativePath(mediaKey, relativePath);
    final file = File(p.join(_supportDirectory.path, relativePath));
    return await file.exists() ? file : null;
  }

  Future<File?> legacyAssetFile(int assetId) async {
    final asset = getLegacyAsset(assetId);
    if (asset == null) return null;
    return mediaFileForKey(asset.mediaKey);
  }

  /// Copies a legacy asset's ordinary file into the managed media directory.
  Future<File> storeLegacyAssetFile({
    required int assetId,
    required File sourceFile,
  }) async {
    _ensureOpen();
    final asset = getLegacyAsset(assetId);
    if (asset == null) throw ArgumentError.value(assetId, 'assetId');
    if (!await sourceFile.exists()) {
      throw FileSystemException(
        'Legacy source file does not exist',
        sourceFile.path,
      );
    }
    final fileSize = await sourceFile.length();
    final replacement = await _replaceMediaFile(asset.mediaKey, sourceFile);
    try {
      _transaction(() {
        _database.execute(
          'UPDATE legacy_assets SET file_size = ? WHERE id = ?',
          [fileSize, assetId],
        );
        _database.execute(
          '''
          INSERT INTO media_file_paths (media_key, relative_path, updated_at)
          VALUES (?, ?, ?)
          ON CONFLICT(media_key) DO UPDATE SET
            relative_path = excluded.relative_path,
            updated_at = excluded.updated_at
        ''',
          [asset.mediaKey, _relativeMediaPath(asset.mediaKey), _now()],
        );
      });
      await replacement.commit();
      return _mediaFileForKey(asset.mediaKey);
    } catch (_) {
      await replacement.rollback();
      rethrow;
    }
  }

  /// Copies the live SQLite database to a standard `.sqlite`/`.sqlite3` file.
  Future<File> exportDatabase(File destination) async {
    _ensureOpen();
    final targetPath = p.absolute(destination.path);
    if (p.equals(targetPath, p.absolute(_databaseFile.path))) {
      return _databaseFile;
    }
    await destination.parent.create(recursive: true);
    return _databaseFile.copy(destination.path);
  }

  /// Replaces app data with a standard SQLite database file after validating
  /// and migrating a staged copy. The prior file is retained until reopening
  /// and externalizing any legacy media BLOBs has succeeded.
  Future<void> importDatabase(File source) async {
    _ensureOpen();
    if (!await source.exists()) {
      throw FileSystemException(
        'SQLite source file does not exist',
        source.path,
      );
    }
    if (p.equals(p.absolute(source.path), p.absolute(_databaseFile.path)))
      return;
    final sourceHandle = await source.open(mode: FileMode.read);
    late final List<int> sourceHeader;
    try {
      sourceHeader = await sourceHandle.read(16);
    } finally {
      await sourceHandle.close();
    }
    if (!_hasSqliteHeader(sourceHeader)) {
      throw FormatException('The selected file is not a SQLite database.');
    }

    final nonce = DateTime.now().microsecondsSinceEpoch;
    final staged = File(
      p.join(_supportDirectory.path, 'import-$nonce.sqlite3'),
    );
    final rollback = File(
      p.join(_supportDirectory.path, 'before-import-$nonce.sqlite3'),
    );
    await source.copy(staged.path);

    Database? candidate;
    try {
      candidate = sqlite3.open(staged.path);
      _prepareDatabase(candidate);
      final tableNames = candidate
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'].toString())
          .toSet();
      if (!tableNames.contains('semesters') ||
          !tableNames.contains('members')) {
        throw FormatException(
          'The SQLite file is not a Lion Manager database.',
        );
      }
      _migrateDatabase(candidate);
      await _moveEmbeddedMediaToFiles(candidate);
      candidate.dispose();
      candidate = null;
    } catch (_) {
      candidate?.dispose();
      if (await staged.exists()) await staged.delete();
      rethrow;
    }

    _database.dispose();
    try {
      await _databaseFile.rename(rollback.path);
      try {
        await staged.rename(_databaseFile.path);
      } catch (_) {
        await rollback.rename(_databaseFile.path);
        rethrow;
      }
      _database = sqlite3.open(_databaseFile.path);
      _prepareDatabase(_database);
      await rollback.delete();
    } catch (_) {
      if (!await _databaseFile.exists() && await rollback.exists()) {
        await rollback.rename(_databaseFile.path);
      }
      _database = sqlite3.open(_databaseFile.path);
      _prepareDatabase(_database);
      rethrow;
    }
  }

  Future<void> _moveEmbeddedMediaToFiles(Database database) async {
    final rows = database.select('''
      SELECT id, media_key, file_name, file_data
      FROM media_assets
      WHERE file_data IS NOT NULL AND length(file_data) > 0
      ORDER BY id
    ''');
    for (final row in rows) {
      final key = row['media_key']?.toString() ?? '';
      _validateMediaKey(key);
      final blob = row['file_data'];
      if (blob is! List<int>) {
        throw StateError('A media asset has an unreadable embedded payload.');
      }
      final replacement = await _replaceMediaBytes(key, blob);
      try {
        database.execute('BEGIN IMMEDIATE');
        try {
          database.execute(
            "UPDATE media_assets SET file_data = X'', file_size = ? WHERE id = ?",
            [blob.length, row['id']],
          );
          database.execute(
            '''
            INSERT INTO media_file_paths (media_key, relative_path, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(media_key) DO UPDATE SET
              relative_path = excluded.relative_path,
              updated_at = excluded.updated_at
          ''',
            [key, _relativeMediaPath(key), _now()],
          );
          database.execute('COMMIT');
        } catch (_) {
          database.execute('ROLLBACK');
          rethrow;
        }
        await replacement.commit();
      } catch (_) {
        await replacement.rollback();
        rethrow;
      }
    }
  }

  Future<_FileReplacement> _replaceMediaBytes(
    String mediaKey,
    List<int> bytes,
  ) async {
    _validateMediaKey(mediaKey);
    final destination = _mediaFileForKey(mediaKey);
    final temporary = await _newMediaTemporary(mediaKey);
    await temporary.writeAsBytes(bytes, flush: true);
    return _installMediaTemporary(destination, temporary);
  }

  Future<_FileReplacement> _replaceMediaFile(
    String mediaKey,
    File sourceFile,
  ) async {
    _validateMediaKey(mediaKey);
    final destination = _mediaFileForKey(mediaKey);
    final temporary = await _newMediaTemporary(mediaKey);
    await sourceFile.copy(temporary.path);
    return _installMediaTemporary(destination, temporary);
  }

  Future<File> _newMediaTemporary(String mediaKey) async {
    _validateMediaKey(mediaKey);
    final mediaDirectory = Directory(
      p.join(_supportDirectory.path, _mediaDirectoryName),
    );
    await mediaDirectory.create(recursive: true);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    return File(p.join(mediaDirectory.path, '.$mediaKey.part-$suffix'));
  }

  Future<_FileReplacement> _installMediaTemporary(
    File destination,
    File temporary,
  ) async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final backup = File('${destination.path}.previous-$suffix');
    var hadBackup = false;
    try {
      if (await destination.exists()) {
        await destination.rename(backup.path);
        hadBackup = true;
      }
      await temporary.rename(destination.path);
      return _FileReplacement(
        destination: destination,
        backup: hadBackup ? backup : null,
        temporary: temporary,
      );
    } catch (_) {
      if (hadBackup && await backup.exists()) {
        await backup.rename(destination.path);
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  File _mediaFileForKey(String mediaKey) {
    _validateMediaKey(mediaKey);
    return File(p.join(_supportDirectory.path, _mediaDirectoryName, mediaKey));
  }

  static String _relativeMediaPath(String mediaKey) {
    _validateMediaKey(mediaKey);
    return '$_mediaDirectoryName/$mediaKey';
  }

  static void _validateMediaRelativePath(String mediaKey, String relativePath) {
    final normalized = p.posix.normalize(relativePath.replaceAll('\\', '/'));
    if (normalized != _relativeMediaPath(mediaKey)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Media paths must be keyed as media/<media_key>.',
      );
    }
  }

  static String _newMediaKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static void _validateMediaKey(String mediaKey) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(mediaKey)) {
      throw ArgumentError.value(mediaKey, 'mediaKey', 'Invalid media key.');
    }
  }

  List<Map<String, Object?>> _select(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    _ensureOpen();
    final rows = _database.select(sql, parameters);
    return rows
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
  }

  int get _changedRows {
    final row = _database.select('SELECT changes() AS changed').first;
    return (row['changed'] as num).toInt();
  }

  T _transaction<T>(T Function() operation) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final result = operation();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _requireExists(String table, int id, String label) {
    final rows = _database.select(
      'SELECT 1 AS found FROM $table WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) throw ArgumentError('$label $id does not exist.');
  }

  void _requireChangedRow(String label, int id) {
    if (_changedRows == 0) throw ArgumentError('$label $id does not exist.');
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  static bool _hasSqliteHeader(List<int> bytes) =>
      bytes.length >= 16 &&
      String.fromCharCodes(bytes.take(16)) == 'SQLite format 3\u0000';

  void _ensureOpen() {
    if (_closed) throw StateError('LionRepository has been closed.');
  }

  void close() {
    if (_closed) return;
    _database.dispose();
    _closed = true;
  }
}

class _FileReplacement {
  const _FileReplacement({
    required this.destination,
    required this.backup,
    required this.temporary,
  });

  final File destination;
  final File? backup;
  final File temporary;

  Future<void> commit() async {
    final previous = backup;
    if (previous != null && await previous.exists()) await previous.delete();
    if (await temporary.exists()) await temporary.delete();
  }

  Future<void> rollback() async {
    if (await destination.exists()) await destination.delete();
    final previous = backup;
    if (previous != null && await previous.exists()) {
      await previous.rename(destination.path);
    }
    if (await temporary.exists()) await temporary.delete();
  }
}
