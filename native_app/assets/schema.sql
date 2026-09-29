PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS semesters (
  id INTEGER PRIMARY KEY,
  label TEXT NOT NULL UNIQUE,
  start_date TEXT,
  end_date TEXT,
  is_current INTEGER NOT NULL DEFAULT 0 CHECK (is_current IN (0, 1))
);

CREATE TABLE IF NOT EXISTS members (
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
);

CREATE TABLE IF NOT EXISTS attendance_sessions (
  id INTEGER PRIMARY KEY,
  semester_id INTEGER NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
  session_date TEXT NOT NULL,
  start_time TEXT NOT NULL DEFAULT '18:00',
  end_time TEXT NOT NULL DEFAULT '20:00',
  title TEXT NOT NULL DEFAULT '狮队训练',
  notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS attendance_records (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES attendance_sessions(id) ON DELETE CASCADE,
  member_id INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('present', 'absent', 'pending')),
  note TEXT NOT NULL DEFAULT '',
  UNIQUE (session_id, member_id)
);

CREATE TABLE IF NOT EXISTS routines (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  music TEXT NOT NULL DEFAULT '',
  movements TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  event_date TEXT NOT NULL DEFAULT '',
  location TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS event_members (
  event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  member_id INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  PRIMARY KEY (event_id, member_id)
);

CREATE TABLE IF NOT EXISTS documents (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  document_type TEXT NOT NULL DEFAULT '通讯稿',
  document_date TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  legacy_asset_id INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS training_plans (
  id INTEGER PRIMARY KEY,
  semester_id INTEGER NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  legacy_asset_id INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS finance_entries (
  id INTEGER PRIMARY KEY,
  transaction_date TEXT NOT NULL,
  entry_type TEXT NOT NULL CHECK (entry_type IN ('income', 'expense', 'wage')),
  title TEXT NOT NULL,
  amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
  member_id INTEGER REFERENCES members(id) ON DELETE SET NULL,
  notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media_assets (
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
);

CREATE TABLE IF NOT EXISTS legacy_assets (
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
);

CREATE TABLE IF NOT EXISTS routine_legacy_assets (
  routine_id INTEGER NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  legacy_asset_id INTEGER NOT NULL REFERENCES legacy_assets(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'reference',
  PRIMARY KEY (routine_id, legacy_asset_id)
);

CREATE TABLE IF NOT EXISTS event_legacy_assets (
  event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  legacy_asset_id INTEGER NOT NULL REFERENCES legacy_assets(id) ON DELETE CASCADE,
  PRIMARY KEY (event_id, legacy_asset_id)
);

CREATE INDEX IF NOT EXISTS idx_members_semester ON members(semester_id, name);
CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance_sessions(session_date DESC);
CREATE INDEX IF NOT EXISTS idx_events_date ON events(event_date DESC);
CREATE INDEX IF NOT EXISTS idx_finance_date ON finance_entries(transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_legacy_category ON legacy_assets(category, group_name, title);
CREATE INDEX IF NOT EXISTS idx_media_owner ON media_assets(owner_type, owner_id);

PRAGMA user_version = 2;
