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

  static const int schemaVersion = 4;
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
    if (version == schemaVersion) return;

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
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  static const List<String> _createTableStatements = [
    '''CREATE TABLE IF NOT EXISTS semesters (
      id INTEGER PRIMARY KEY,
      label TEXT NOT NULL UNIQUE,
      start_date TEXT,
      end_date TEXT,
      is_current INTEGER NOT NULL DEFAULT 0 CHECK (is_current IN (0, 1))
    )''',
    '''CREATE TABLE IF NOT EXISTS members (
      id INTEGER PRIMARY KEY,
      semester_id INTEGER NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
      student_no TEXT NOT NULL DEFAULT '',
      name TEXT NOT NULL,
      grade TEXT NOT NULL DEFAULT '',
      major TEXT NOT NULL DEFAULT '',
      position TEXT NOT NULL DEFAULT '',
      birthday TEXT NOT NULL DEFAULT '',
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
      'semester_id': 'INTEGER NOT NULL DEFAULT 0',
      'student_no': "TEXT NOT NULL DEFAULT ''",
      'name': "TEXT NOT NULL DEFAULT ''",
      'grade': "TEXT NOT NULL DEFAULT ''",
      'major': "TEXT NOT NULL DEFAULT ''",
      'position': "TEXT NOT NULL DEFAULT ''",
      'birthday': "TEXT NOT NULL DEFAULT ''",
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
      SELECT id, semester_id, student_no, name, grade, major, position, birthday, notes, active
      FROM members WHERE semester_id = ?$activeClause ORDER BY name, id
    ''',
      [semesterId],
    ).map(Member.fromMap).toList(growable: false);
  }

  Member? getMember(int memberId) {
    _ensureOpen();
    final rows = _select(
      '''
      SELECT id, semester_id, student_no, name, grade, major, position, birthday, notes, active
      FROM members WHERE id = ?
    ''',
      [memberId],
    );
    return rows.isEmpty ? null : Member.fromMap(rows.first);
  }

  /// Returns the roster rows for the same member across semesters.
  /// Without a student number, only the selected roster row is returned.
  List<Member> getMemberSemesterHistory(Member member) {
    _ensureOpen();
    final studentNo = member.studentNo.trim();
    final rows = studentNo.isEmpty
        ? _select(
            '''
            SELECT id, semester_id, student_no, name, grade, major, position,
                   birthday, notes, active
            FROM members WHERE id = ?
          ''',
            [member.id],
          )
        : _select(
            '''
            SELECT id, semester_id, student_no, name, grade, major, position,
                   birthday, notes, active
            FROM members
            WHERE trim(student_no) = ?
            ORDER BY
              (SELECT start_date FROM semesters WHERE semesters.id = members.semester_id),
              semester_id, id
          ''',
            [studentNo],
          );
    return rows.map(Member.fromMap).toList(growable: false);
  }

  int addMember({
    required int semesterId,
    required String name,
    String studentNo = '',
    String grade = '',
    String major = '',
    String position = '',
    String birthday = '',
    String notes = '',
    bool active = true,
  }) {
    _ensureOpen();
    _database.execute(
      '''INSERT INTO members
         (semester_id, student_no, name, grade, major, position, birthday, notes, active)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        semesterId,
        studentNo,
        name,
        grade,
        major,
        position,
        birthday,
        notes,
        active ? 1 : 0,
      ],
    );
    return _database.lastInsertRowId;
  }

  void updateMember(Member member) {
    _ensureOpen();
    _database.execute(
      '''UPDATE members SET semester_id = ?, student_no = ?, name = ?, grade = ?,
         major = ?, position = ?, birthday = ?, notes = ?, active = ? WHERE id = ?''',
      [
        member.semesterId,
        member.studentNo,
        member.name,
        member.grade,
        member.major,
        member.position,
        member.birthday,
        member.notes,
        member.active ? 1 : 0,
        member.id,
      ],
    );
    _requireChangedRow('Member', member.id);
  }

  void deleteMember(int memberId) {
    _ensureOpen();
    _database.execute('DELETE FROM members WHERE id = ?', [memberId]);
  }

  /// Copies roster fields into another semester, leaving existing rows intact.
  /// Duplicate `(student_no, name)` pairs are skipped by the v2 unique key.
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
          (semester_id, student_no, name, grade, major, position, birthday, notes, active)
        SELECT ?, student_no, name, grade, major, position, birthday, notes, active
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

  List<EventModel> getEvents({String? fromDate, String? throughDate}) {
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
    final whereClause = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _select('''
      SELECT id, title, event_date, location, summary, created_at, updated_at
      FROM events $whereClause ORDER BY event_date DESC, id DESC
    ''', values).map(EventModel.fromMap).toList(growable: false);
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
      SELECT id, title, event_date, location, summary, created_at, updated_at
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
  }) {
    _ensureOpen();
    final now = _now();
    _database.execute(
      '''INSERT INTO events
         (title, event_date, location, summary, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [title, eventDate, location, summary, now, now],
    );
    return _database.lastInsertRowId;
  }

  void updateEvent(EventModel event) {
    _ensureOpen();
    _database.execute(
      '''UPDATE events
         SET title = ?, event_date = ?, location = ?, summary = ?, updated_at = ?
         WHERE id = ?''',
      [
        event.title,
        event.eventDate,
        event.location,
        event.summary,
        _now(),
        event.id,
      ],
    );
    _requireChangedRow('Event', event.id);
  }

  void deleteEvent(int eventId) {
    _ensureOpen();
    _database.execute('DELETE FROM events WHERE id = ?', [eventId]);
  }

  List<Member> getEventParticipants(int eventId) {
    _ensureOpen();
    return _select(
      '''
      SELECT m.id, m.semester_id, m.student_no, m.name, m.grade, m.major, m.position,
             m.birthday, m.notes, m.active
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
