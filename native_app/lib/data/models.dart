/// Typed records used by [LionRepository].
///
/// Dates and times remain ISO-like strings because the v2 SQLite schema stores
/// them as TEXT. Money is always represented in integer cents.
library;

enum AttendanceStatus {
  pending('pending'),
  present('present'),
  absent('absent');

  const AttendanceStatus(this.sqliteValue);

  final String sqliteValue;

  static AttendanceStatus fromSqlite(Object? value) {
    return AttendanceStatus.values.firstWhere(
      (status) => status.sqliteValue == value,
      orElse: () => throw FormatException('Unknown attendance status: $value'),
    );
  }
}

enum FinanceEntryType {
  income('income'),
  expense('expense'),
  wage('wage');

  const FinanceEntryType(this.sqliteValue);

  final String sqliteValue;

  static FinanceEntryType fromSqlite(Object? value) {
    return FinanceEntryType.values.firstWhere(
      (type) => type.sqliteValue == value,
      orElse: () => throw FormatException('Unknown finance entry type: $value'),
    );
  }
}

int _intValue(Map<String, Object?> row, String key, {int fallback = 0}) {
  final value = row[key];
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? fallback;
}

String _stringValue(
  Map<String, Object?> row,
  String key, {
  String fallback = '',
}) {
  return row[key]?.toString() ?? fallback;
}

String? _nullableStringValue(Map<String, Object?> row, String key) {
  final value = row[key];
  return value == null ? null : value.toString();
}

bool _boolValue(Map<String, Object?> row, String key) {
  final value = row[key];
  return value == true || value == 1 || value == '1';
}

class Semester {
  const Semester({
    required this.id,
    required this.label,
    this.startDate,
    this.endDate,
    required this.isCurrent,
  });

  final int id;
  final String label;
  final String? startDate;
  final String? endDate;
  final bool isCurrent;

  factory Semester.fromMap(Map<String, Object?> row) => Semester(
    id: _intValue(row, 'id'),
    label: _stringValue(row, 'label'),
    startDate: _nullableStringValue(row, 'start_date'),
    endDate: _nullableStringValue(row, 'end_date'),
    isCurrent: _boolValue(row, 'is_current'),
  );
}

/// A stable identity shared by one person's semester-specific roster records.
class PersonProfile {
  const PersonProfile({
    required this.id,
    required this.displayName,
    required this.birthday,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String displayName;
  final String birthday;
  final String createdAt;
  final String updatedAt;

  factory PersonProfile.fromMap(Map<String, Object?> row) => PersonProfile(
    id: _intValue(row, 'id'),
    displayName: _stringValue(row, 'display_name'),
    birthday: _stringValue(row, 'birthday'),
    createdAt: _stringValue(row, 'created_at'),
    updatedAt: _stringValue(row, 'updated_at'),
  );
}

class Member {
  const Member({
    required this.id,
    required this.personId,
    required this.semesterId,
    required this.studentNo,
    required this.name,
    required this.grade,
    required this.major,
    required this.position,
    required this.birthday,
    this.contact,
    required this.notes,
    required this.active,
  });

  final int id;
  final int personId;
  final int semesterId;
  final String studentNo;
  final String name;
  final String grade;
  final String major;
  final String position;
  final String birthday;
  final String? contact;
  final String notes;
  final bool active;

  factory Member.fromMap(Map<String, Object?> row) => Member(
    id: _intValue(row, 'id'),
    personId: _intValue(row, 'person_id'),
    semesterId: _intValue(row, 'semester_id'),
    studentNo: _stringValue(row, 'student_no'),
    name: _stringValue(row, 'name'),
    grade: _stringValue(row, 'grade'),
    major: _stringValue(row, 'major'),
    position: _stringValue(row, 'position'),
    birthday: _stringValue(row, 'birthday'),
    contact: _stringValue(row, 'contact'),
    notes: _stringValue(row, 'notes'),
    active: _boolValue(row, 'active'),
  );
}

class AttendanceSession {
  const AttendanceSession({
    required this.id,
    required this.semesterId,
    required this.sessionDate,
    required this.startTime,
    required this.endTime,
    required this.title,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final int semesterId;
  final String sessionDate;
  final String startTime;
  final String endTime;
  final String title;
  final String notes;
  final String createdAt;
  final String updatedAt;

  factory AttendanceSession.fromMap(Map<String, Object?> row) =>
      AttendanceSession(
        id: _intValue(row, 'id'),
        semesterId: _intValue(row, 'semester_id'),
        sessionDate: _stringValue(row, 'session_date'),
        startTime: _stringValue(row, 'start_time', fallback: '18:00'),
        endTime: _stringValue(row, 'end_time', fallback: '20:00'),
        title: _stringValue(row, 'title'),
        notes: _stringValue(row, 'notes'),
        createdAt: _stringValue(row, 'created_at'),
        updatedAt: _stringValue(row, 'updated_at'),
      );
}

class AttendanceRecord {
  const AttendanceRecord({
    required this.id,
    required this.sessionId,
    required this.memberId,
    required this.status,
    required this.note,
    this.memberName,
  });

  final int id;
  final int sessionId;
  final int memberId;
  final AttendanceStatus status;
  final String note;
  final String? memberName;

  factory AttendanceRecord.fromMap(Map<String, Object?> row) =>
      AttendanceRecord(
        id: _intValue(row, 'id'),
        sessionId: _intValue(row, 'session_id'),
        memberId: _intValue(row, 'member_id'),
        status: AttendanceStatus.fromSqlite(row['status']),
        note: _stringValue(row, 'note'),
        memberName: _nullableStringValue(row, 'member_name'),
      );
}

class EventModel {
  const EventModel({
    required this.id,
    required this.title,
    required this.eventDate,
    required this.location,
    required this.summary,
    this.semesterId,
    this.recurringActivityId,
    this.eventType,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String title;
  final String eventDate;
  final String location;
  final String summary;
  final int? semesterId;
  final int? recurringActivityId;
  final String? eventType;
  final String createdAt;
  final String updatedAt;

  factory EventModel.fromMap(Map<String, Object?> row) => EventModel(
    id: _intValue(row, 'id'),
    title: _stringValue(row, 'title'),
    eventDate: _stringValue(row, 'event_date'),
    location: _stringValue(row, 'location'),
    summary: _stringValue(row, 'summary'),
    semesterId: row['semester_id'] == null
        ? null
        : _intValue(row, 'semester_id'),
    recurringActivityId: row['recurring_activity_id'] == null
        ? null
        : _intValue(row, 'recurring_activity_id'),
    eventType: _nullableStringValue(row, 'event_type'),
    createdAt: _stringValue(row, 'created_at'),
    updatedAt: _stringValue(row, 'updated_at'),
  );
}

class RecurringActivityModel {
  const RecurringActivityModel({
    required this.id,
    required this.title,
    required this.activityType,
    required this.description,
    required this.active,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String title;
  final String activityType;
  final String description;
  final bool active;
  final String createdAt;
  final String updatedAt;

  factory RecurringActivityModel.fromMap(Map<String, Object?> row) =>
      RecurringActivityModel(
        id: _intValue(row, 'id'),
        title: _stringValue(row, 'title'),
        activityType: _stringValue(row, 'activity_type'),
        description: _stringValue(row, 'description'),
        active: _boolValue(row, 'active'),
        createdAt: _stringValue(row, 'created_at'),
        updatedAt: _stringValue(row, 'updated_at'),
      );
}

enum InventoryMovementType {
  received('received'),
  purchased('purchased'),
  found('found'),
  lost('lost'),
  stolen('stolen'),
  disposed('disposed'),
  adjustment('adjustment');

  const InventoryMovementType(this.sqliteValue);

  final String sqliteValue;

  bool get isInbound => this == received || this == purchased || this == found;

  bool get isOutbound => this == lost || this == stolen || this == disposed;

  static InventoryMovementType fromSqlite(Object? value) =>
      InventoryMovementType.values.firstWhere(
        (type) => type.sqliteValue == value,
        orElse: () =>
            throw FormatException('Unknown inventory movement type: $value'),
      );
}

class InventoryItemModel {
  const InventoryItemModel({
    required this.id,
    required this.name,
    this.category = '',
    this.unit = '',
    required this.currentQuantity,
    required this.location,
    required this.condition,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String name;
  final String category;
  final String unit;
  final int currentQuantity;
  final String location;
  final String condition;
  final String notes;
  final String createdAt;
  final String updatedAt;

  factory InventoryItemModel.fromMap(Map<String, Object?> row) =>
      InventoryItemModel(
        id: _intValue(row, 'id'),
        name: _stringValue(row, 'name'),
        category: _stringValue(row, 'category'),
        unit: _stringValue(row, 'unit'),
        currentQuantity: _intValue(row, 'current_quantity'),
        location: _stringValue(row, 'location'),
        condition: _stringValue(row, 'condition'),
        notes: _stringValue(row, 'notes'),
        createdAt: _stringValue(row, 'created_at'),
        updatedAt: _stringValue(row, 'updated_at'),
      );
}

class InventoryMovementModel {
  const InventoryMovementModel({
    required this.id,
    required this.itemId,
    required this.movementType,
    required this.quantityDelta,
    required this.movementDate,
    required this.notes,
    required this.createdAt,
  });

  final int id;
  final int itemId;
  final InventoryMovementType movementType;

  /// Positive means inventory increased; negative means it decreased.
  final int quantityDelta;
  final String movementDate;
  final String notes;
  final String createdAt;

  factory InventoryMovementModel.fromMap(Map<String, Object?> row) =>
      InventoryMovementModel(
        id: _intValue(row, 'id'),
        itemId: _intValue(row, 'item_id'),
        movementType: InventoryMovementType.fromSqlite(row['movement_type']),
        quantityDelta: _intValue(row, 'quantity_delta'),
        movementDate: _stringValue(row, 'movement_date'),
        notes: _stringValue(row, 'notes'),
        createdAt: _stringValue(row, 'created_at'),
      );
}

class RoutineModel {
  const RoutineModel({
    required this.id,
    required this.title,
    required this.music,
    required this.movements,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String title;
  final String music;
  final String movements;
  final String notes;
  final String createdAt;
  final String updatedAt;

  factory RoutineModel.fromMap(Map<String, Object?> row) => RoutineModel(
    id: _intValue(row, 'id'),
    title: _stringValue(row, 'title'),
    music: _stringValue(row, 'music'),
    movements: _stringValue(row, 'movements'),
    notes: _stringValue(row, 'notes'),
    createdAt: _stringValue(row, 'created_at'),
    updatedAt: _stringValue(row, 'updated_at'),
  );
}

class DocumentModel {
  const DocumentModel({
    required this.id,
    required this.title,
    required this.documentType,
    required this.documentDate,
    required this.content,
    required this.legacyAssetId,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String title;
  final String documentType;
  final String documentDate;
  final String content;
  final int? legacyAssetId;
  final String createdAt;
  final String updatedAt;

  factory DocumentModel.fromMap(Map<String, Object?> row) => DocumentModel(
    id: _intValue(row, 'id'),
    title: _stringValue(row, 'title'),
    documentType: _stringValue(row, 'document_type'),
    documentDate: _stringValue(row, 'document_date'),
    content: _stringValue(row, 'content'),
    legacyAssetId: row['legacy_asset_id'] == null
        ? null
        : _intValue(row, 'legacy_asset_id'),
    createdAt: _stringValue(row, 'created_at'),
    updatedAt: _stringValue(row, 'updated_at'),
  );
}

class TrainingPlanModel {
  const TrainingPlanModel({
    required this.id,
    required this.semesterId,
    required this.title,
    required this.content,
    required this.legacyAssetId,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final int semesterId;
  final String title;
  final String content;
  final int? legacyAssetId;
  final String createdAt;
  final String updatedAt;

  factory TrainingPlanModel.fromMap(Map<String, Object?> row) =>
      TrainingPlanModel(
        id: _intValue(row, 'id'),
        semesterId: _intValue(row, 'semester_id'),
        title: _stringValue(row, 'title'),
        content: _stringValue(row, 'content'),
        legacyAssetId: row['legacy_asset_id'] == null
            ? null
            : _intValue(row, 'legacy_asset_id'),
        createdAt: _stringValue(row, 'created_at'),
        updatedAt: _stringValue(row, 'updated_at'),
      );
}

class FinanceEntryModel {
  const FinanceEntryModel({
    required this.id,
    required this.transactionDate,
    required this.entryType,
    required this.title,
    required this.amountCents,
    required this.memberId,
    required this.notes,
    required this.createdAt,
  });

  final int id;
  final String transactionDate;
  final FinanceEntryType entryType;
  final String title;
  final int amountCents;
  final int? memberId;
  final String notes;
  final String createdAt;

  factory FinanceEntryModel.fromMap(Map<String, Object?> row) =>
      FinanceEntryModel(
        id: _intValue(row, 'id'),
        transactionDate: _stringValue(row, 'transaction_date'),
        entryType: FinanceEntryType.fromSqlite(row['entry_type']),
        title: _stringValue(row, 'title'),
        amountCents: _intValue(row, 'amount_cents'),
        memberId: row['member_id'] == null ? null : _intValue(row, 'member_id'),
        notes: _stringValue(row, 'notes'),
        createdAt: _stringValue(row, 'created_at'),
      );
}

class LegacyAssetModel {
  const LegacyAssetModel({
    required this.id,
    required this.mediaKey,
    required this.title,
    required this.category,
    required this.groupName,
    required this.relativePath,
    required this.originalPath,
    required this.mimeType,
    required this.fileSize,
    required this.notes,
  });

  final int id;
  final String mediaKey;
  final String title;
  final String category;
  final String groupName;
  final String relativePath;
  final String originalPath;
  final String mimeType;
  final int fileSize;
  final String notes;

  factory LegacyAssetModel.fromMap(Map<String, Object?> row) =>
      LegacyAssetModel(
        id: _intValue(row, 'id'),
        mediaKey: _stringValue(row, 'media_key'),
        title: _stringValue(row, 'title'),
        category: _stringValue(row, 'category'),
        groupName: _stringValue(row, 'group_name'),
        relativePath: _stringValue(row, 'relative_path'),
        originalPath: _stringValue(row, 'original_path'),
        mimeType: _stringValue(
          row,
          'mime_type',
          fallback: 'application/octet-stream',
        ),
        fileSize: _intValue(row, 'file_size'),
        notes: _stringValue(row, 'notes'),
      );
}

class MediaAssetModel {
  const MediaAssetModel({
    required this.id,
    required this.mediaKey,
    required this.ownerType,
    required this.ownerId,
    required this.role,
    required this.title,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.relativePath,
    required this.createdAt,
  });

  final int id;
  final String mediaKey;
  final String ownerType;
  final int ownerId;
  final String role;
  final String title;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final String relativePath;
  final String createdAt;

  factory MediaAssetModel.fromMap(Map<String, Object?> row) => MediaAssetModel(
    id: _intValue(row, 'id'),
    mediaKey: _stringValue(row, 'media_key'),
    ownerType: _stringValue(row, 'owner_type'),
    ownerId: _intValue(row, 'owner_id'),
    role: _stringValue(row, 'role'),
    title: _stringValue(row, 'title'),
    fileName: _stringValue(row, 'file_name'),
    mimeType: _stringValue(row, 'mime_type'),
    fileSize: _intValue(row, 'file_size'),
    relativePath: _stringValue(row, 'relative_path'),
    createdAt: _stringValue(row, 'created_at'),
  );
}
