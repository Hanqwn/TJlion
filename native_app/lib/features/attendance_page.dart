import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  List<Semester> _semesters = const [];
  List<AttendanceSession> _sessions = const [];
  int? _semesterId;
  DateTime _selectedDate = _dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _reloadSemesters();
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  String _dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  DateTime _parseDate(String value) {
    final parsed = DateTime.tryParse(value);
    return parsed == null ? _dateOnly(DateTime.now()) : _dateOnly(parsed);
  }

  void _reloadSemesters({int? preferredSemesterId}) {
    final semesters = widget.repository.getSemesters();
    final preferred = preferredSemesterId ?? _semesterId;
    final selected = semesters.any((item) => item.id == preferred)
        ? preferred
        : widget.repository.getCurrentSemester()?.id ??
              (semesters.isEmpty ? null : semesters.first.id);
    setState(() {
      _semesters = semesters;
      _semesterId = selected;
      _sessions = selected == null
          ? const []
          : widget.repository.getAttendanceSessions(selected);
    });
  }

  void _reloadSessions() {
    final semesterId = _semesterId;
    setState(() {
      _sessions = semesterId == null
          ? const []
          : widget.repository.getAttendanceSessions(semesterId);
    });
  }

  List<AttendanceSession> get _selectedDaySessions {
    final date = _dateString(_selectedDate);
    return _sessions.where((session) => session.sessionDate == date).toList();
  }

  Future<void> _addSession() async {
    final semesterId = _semesterId;
    if (semesterId == null) return;
    final draft = await showDialog<_SessionDraft>(
      context: context,
      builder: (context) => _AttendanceSessionDialog(
        repository: widget.repository,
        semesterId: semesterId,
        initialDate: _selectedDate,
      ),
    );
    if (draft == null || !mounted) return;
    _saveDraft(draft, null);
  }

  Future<void> _editSession(AttendanceSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('进入出勤编辑？'),
        content: Text(
          '即将编辑 ${session.sessionDate} ${session.startTime}–${session.endTime} 的训练记录。\n\n'
          '确认后可以修改训练信息、每位成员的出勤状态和备注。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('进入编辑'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final draft = await showDialog<_SessionDraft>(
      context: context,
      builder: (context) => _AttendanceSessionDialog(
        repository: widget.repository,
        semesterId: session.semesterId,
        initialDate: _parseDate(session.sessionDate),
        session: session,
      ),
    );
    if (draft == null || !mounted) return;
    _saveDraft(draft, session);
  }

  void _saveDraft(_SessionDraft draft, AttendanceSession? existing) {
    final semesterId = existing?.semesterId ?? _semesterId;
    if (semesterId == null) return;
    try {
      final sessionId = existing == null
          ? widget.repository.addAttendanceSession(
              semesterId: semesterId,
              sessionDate: _dateString(draft.date),
              startTime: draft.startTime,
              endTime: draft.endTime,
              title: draft.title,
              notes: draft.notes,
            )
          : existing.id;
      if (existing != null) {
        widget.repository.updateAttendanceSession(
          AttendanceSession(
            id: existing.id,
            semesterId: existing.semesterId,
            sessionDate: _dateString(draft.date),
            startTime: draft.startTime,
            endTime: draft.endTime,
            title: draft.title,
            notes: draft.notes,
            createdAt: existing.createdAt,
            updatedAt: existing.updatedAt,
          ),
        );
      }
      for (final attendee in draft.attendees) {
        widget.repository.saveAttendanceRecord(
          sessionId: sessionId,
          memberId: attendee.member.id,
          status: attendee.status,
          note: attendee.note,
        );
      }
      setState(() {
        _selectedDate = _dateOnly(draft.date);
        _sessions = widget.repository.getAttendanceSessions(semesterId);
      });
      _showMessage(existing == null ? '训练出勤已记录' : '出勤记录已更新');
    } catch (error) {
      _showMessage('保存失败：$error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        height: 48,
                        width: 48,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.fact_check_outlined,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '训练出勤',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '按日期查看训练，并记录每位成员的状态',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      if (MediaQuery.sizeOf(context).width < 520)
                        IconButton.filledTonal(
                          onPressed: _semesterId == null ? null : _addSession,
                          tooltip: '记录训练',
                          icon: const Icon(Icons.add),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _semesterId == null ? null : _addSession,
                          icon: const Icon(Icons.add),
                          label: const Text('记录训练'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Card(
                    elevation: 0,
                    color: colors.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.school_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _semesterId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '出勤学期',
                                border: OutlineInputBorder(),
                              ),
                              items: _semesters
                                  .map(
                                    (semester) => DropdownMenuItem(
                                      value: semester.id,
                                      child: Text(
                                        semester.label,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() {
                                  _semesterId = value;
                                  _sessions = widget.repository
                                      .getAttendanceSessions(value);
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 14),
                          Chip(
                            avatar: const Icon(
                              Icons.event_available_outlined,
                              size: 18,
                            ),
                            label: Text('${_sessions.length} 场训练'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(child: _buildCalendarAndSessions(colors)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCalendarAndSessions(ColorScheme colors) {
    if (_semesters.isEmpty) {
      return const _AttendanceEmptyState(
        icon: Icons.event_busy_outlined,
        title: '还没有学期',
        message: '请先在学期管理中建立学期，再记录训练出勤。',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final recentDates =
            _sessions.map((session) => session.sessionDate).toSet().toList()
              ..sort((left, right) => right.compareTo(left));
        final calendar = Card(
          elevation: 0,
          color: colors.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.calendar_month_outlined,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '训练日历',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                CalendarDatePicker(
                  initialDate: _selectedDate,
                  firstDate: DateTime(1990),
                  lastDate: DateTime(2100),
                  currentDate: DateTime.now(),
                  onDateChanged: (date) =>
                      setState(() => _selectedDate = _dateOnly(date)),
                ),
                const SizedBox(height: 4),
                Text(
                  '常规安排：周二 18:00–20:00 · 周日 09:00–11:00',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                if (recentDates.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '最近训练',
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 2,
                    children: recentDates.take(8).map((date) {
                      final selected = date == _dateString(_selectedDate);
                      return ChoiceChip(
                        label: Text(
                          date.length >= 10 ? date.substring(5) : date,
                        ),
                        selected: selected,
                        onSelected: (_) =>
                            setState(() => _selectedDate = _parseDate(date)),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        );
        final sessions = _DaySessionsPanel(
          date: _selectedDate,
          sessions: _selectedDaySessions,
          repository: widget.repository,
          compact: constraints.maxWidth < 800,
          onAdd: _addSession,
          onEdit: _editSession,
        );
        if (constraints.maxWidth < 800) {
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              children: [calendar, const SizedBox(height: 12), sessions],
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 390, child: calendar),
            const SizedBox(width: 14),
            Expanded(child: sessions),
          ],
        );
      },
    );
  }
}

class _DaySessionsPanel extends StatelessWidget {
  const _DaySessionsPanel({
    required this.date,
    required this.sessions,
    required this.repository,
    required this.compact,
    required this.onAdd,
    required this.onEdit,
  });

  final DateTime date;
  final List<AttendanceSession> sessions;
  final LionRepository repository;
  final bool compact;
  final VoidCallback onAdd;
  final ValueChanged<AttendanceSession> onEdit;

  String _dateString(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _weekday(int weekday) =>
      const ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${date.year}年${date.month}月${date.day}日  ${_weekday(date.weekday)}',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _dateString(date),
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (MediaQuery.sizeOf(context).width < 520)
                  IconButton.filledTonal(
                    onPressed: onAdd,
                    tooltip: '添加训练',
                    icon: const Icon(Icons.add),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('添加训练'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (sessions.isEmpty)
              compact
                  ? Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event_note_outlined,
                            size: 42,
                            color: colors.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '当天还没有训练记录',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '选择其他日期，或为这一天添加训练。',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    )
                  : Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.event_note_outlined,
                                size: 42,
                                color: colors.primary,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '当天还没有训练记录',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '选择其他日期，或为这一天添加训练。',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
            else if (compact)
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: sessions.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) => _SessionCard(
                  session: sessions[index],
                  repository: repository,
                  onEdit: () => onEdit(sessions[index]),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: sessions.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) => _SessionCard(
                    session: sessions[index],
                    repository: repository,
                    onEdit: () => onEdit(sessions[index]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.repository,
    required this.onEdit,
  });

  final AttendanceSession session;
  final LionRepository repository;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final records = repository.getAttendanceRecords(session.id);
    final present = records
        .where((record) => record.status == AttendanceStatus.present)
        .length;
    final absent = records
        .where((record) => record.status == AttendanceStatus.absent)
        .length;
    final pending = records
        .where((record) => record.status == AttendanceStatus.pending)
        .length;
    return Card(
      elevation: 0,
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 42,
                  width: 42,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.sports_martial_arts, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${session.startTime}–${session.endTime}',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: onEdit,
                  tooltip: '编辑出勤',
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            if (session.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(session.notes, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _CountPill(
                  label: '出席 $present',
                  color: colors.tertiaryContainer,
                  foreground: colors.onTertiaryContainer,
                ),
                _CountPill(
                  label: '缺席 $absent',
                  color: colors.errorContainer,
                  foreground: colors.onErrorContainer,
                ),
                _CountPill(
                  label: '待确认 $pending',
                  color: colors.surfaceContainerHighest,
                  foreground: colors.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('查看并编辑出勤'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({
    required this.label,
    required this.color,
    required this.foreground,
  });

  final String label;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(30),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _SessionDraft {
  const _SessionDraft({
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.title,
    required this.notes,
    required this.attendees,
  });

  final DateTime date;
  final String startTime;
  final String endTime;
  final String title;
  final String notes;
  final List<_AttendeeDraft> attendees;
}

class _AttendeeDraft {
  const _AttendeeDraft({
    required this.member,
    required this.status,
    required this.note,
  });

  final Member member;
  final AttendanceStatus status;
  final String note;
}

class _AttendanceSessionDialog extends StatefulWidget {
  const _AttendanceSessionDialog({
    required this.repository,
    required this.semesterId,
    required this.initialDate,
    this.session,
  });

  final LionRepository repository;
  final int semesterId;
  final DateTime initialDate;
  final AttendanceSession? session;

  @override
  State<_AttendanceSessionDialog> createState() =>
      _AttendanceSessionDialogState();
}

class _AttendanceSessionDialogState extends State<_AttendanceSessionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late DateTime _date;
  late String _startTime;
  late String _endTime;
  late final List<_MutableAttendee> _attendees;
  bool _saving = false;

  bool get _isEditing => widget.session != null;

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    _date = session == null
        ? DateTime(
            widget.initialDate.year,
            widget.initialDate.month,
            widget.initialDate.day,
          )
        : _parseDate(session.sessionDate);
    _startTime =
        session?.startTime ??
        (_date.weekday == DateTime.sunday ? '09:00' : '18:00');
    _endTime =
        session?.endTime ??
        (_date.weekday == DateTime.sunday ? '11:00' : '20:00');
    _title = TextEditingController(text: session?.title ?? '狮队训练');
    _notes = TextEditingController(text: session?.notes ?? '');

    final activeMembers = widget.repository.getMembers(
      widget.semesterId,
      activeOnly: true,
    );
    final records = session == null
        ? const <AttendanceRecord>[]
        : widget.repository.getAttendanceRecords(session.id);
    final recordByMember = {
      for (final record in records) record.memberId: record,
    };
    final membersById = {for (final member in activeMembers) member.id: member};
    for (final record in records) {
      final member = widget.repository.getMember(record.memberId);
      if (member != null) membersById[member.id] = member;
    }
    final members = membersById.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    _attendees = members.map((member) {
      final record = recordByMember[member.id];
      return _MutableAttendee(
        member: member,
        status: record?.status ?? AttendanceStatus.pending,
        note: record?.note ?? '',
      );
    }).toList();
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    for (final attendee in _attendees) {
      attendee.dispose();
    }
    super.dispose();
  }

  DateTime _parseDate(String value) =>
      DateTime.tryParse(value) ?? widget.initialDate;

  String _dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _formatTime(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return const TimeOfDay(hour: 18, minute: 0);
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 18,
      minute: int.tryParse(parts[1]) ?? 0,
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
      helpText: '选择训练日期',
    );
    if (picked != null)
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
  }

  DateTime _nextWeekday(DateTime from, int weekday) {
    final daysToAdd = (weekday - from.weekday + 7) % 7;
    final date = DateTime(from.year, from.month, from.day + daysToAdd);
    return date;
  }

  void _setTuesdayDefaults() {
    setState(() {
      _date = _nextWeekday(_date, DateTime.tuesday);
      _startTime = '18:00';
      _endTime = '20:00';
    });
  }

  void _setSundayDefaults() {
    setState(() {
      _date = _nextWeekday(_date, DateTime.sunday);
      _startTime = '09:00';
      _endTime = '11:00';
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final selected = await showTimePicker(
      context: context,
      initialTime: _parseTime(start ? _startTime : _endTime),
      helpText: start ? '选择开始时间' : '选择结束时间',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (selected == null) return;
    setState(() {
      if (start) {
        _startTime = _formatTime(selected);
      } else {
        _endTime = _formatTime(selected);
      }
    });
  }

  int get _presentCount => _attendees
      .where((item) => item.status == AttendanceStatus.present)
      .length;
  int get _absentCount =>
      _attendees.where((item) => item.status == AttendanceStatus.absent).length;
  int get _pendingCount => _attendees
      .where((item) => item.status == AttendanceStatus.pending)
      .length;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final start = _parseTime(_startTime);
    final end = _parseTime(_endTime);
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;
    if (endMinutes <= startMinutes) {
      _showError('结束时间必须晚于开始时间');
      return;
    }
    if (_isEditing) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认保存出勤修改'),
          content: Text(
            '训练日期：${_dateString(_date)}\n'
            '出席：$_presentCount 人\n'
            '缺席：$_absentCount 人\n'
            '待确认：$_pendingCount 人\n\n'
            '请核对日期和出勤人数后保存。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认保存'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _saving = true);
    Navigator.pop(
      context,
      _SessionDraft(
        date: _date,
        startTime: _startTime,
        endTime: _endTime,
        title: _title.text.trim(),
        notes: _notes.text.trim(),
        attendees: _attendees
            .map(
              (item) => _AttendeeDraft(
                member: item.member,
                status: item.status,
                note: item.note.text.trim(),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_isEditing ? '编辑训练出勤' : '记录训练出勤'),
      content: SizedBox(
        width: 760,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _title,
                  decoration: const InputDecoration(
                    labelText: '训练名称',
                    prefixIcon: Icon(Icons.sports_martial_arts),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入训练名称' : null,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text('训练日期  ${_dateString(_date)}'),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(
                        Icons.calendar_today_outlined,
                        size: 18,
                      ),
                      label: const Text('周二 · 18:00–20:00'),
                      onPressed: _setTuesdayDefaults,
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.wb_sunny_outlined, size: 18),
                      label: const Text('周日 · 09:00–11:00'),
                      onPressed: _setSundayDefaults,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _TimeButton(
                        label: '开始时间',
                        value: _startTime,
                        onPressed: () => _pickTime(start: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TimeButton(
                        label: '结束时间',
                        value: _endTime,
                        onPressed: () => _pickTime(start: false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '训练备注',
                    prefixIcon: Icon(Icons.notes_outlined),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '成员出勤',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '出席 $_presentCount · 缺席 $_absentCount · 待确认 $_pendingCount',
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_attendees.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text('这个学期还没有可记录的成员。请先在成员名册中添加成员。'),
                  )
                else
                  ..._attendees.map(
                    (attendee) => _AttendeeEditorRow(
                      attendee: attendee,
                      onChanged: () => setState(() {}),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_isEditing ? '保存修改' : '保存出勤'),
        ),
      ],
    );
  }
}

class _MutableAttendee {
  _MutableAttendee({
    required this.member,
    required this.status,
    required String note,
  }) : note = TextEditingController(text: note);

  final Member member;
  AttendanceStatus status;
  final TextEditingController note;

  void dispose() => note.dispose();
}

class _AttendeeEditorRow extends StatelessWidget {
  const _AttendeeEditorRow({required this.attendee, required this.onChanged});

  final _MutableAttendee attendee;
  final VoidCallback onChanged;

  String _statusLabel(AttendanceStatus status) => switch (status) {
    AttendanceStatus.pending => '待确认',
    AttendanceStatus.present => '出席',
    AttendanceStatus.absent => '缺席',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final member = attendee.member;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: Text(_memberInitial(member.name)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        [
                          if (member.studentNo.trim().isNotEmpty)
                            member.studentNo,
                          if (!member.active) '已停用',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 8,
              children: AttendanceStatus.values.map((status) {
                final selected = attendee.status == status;
                final chipColor = switch (status) {
                  AttendanceStatus.pending => colors.surfaceContainerHighest,
                  AttendanceStatus.present => colors.tertiaryContainer,
                  AttendanceStatus.absent => colors.errorContainer,
                };
                return ChoiceChip(
                  label: Text(_statusLabel(status)),
                  selected: selected,
                  selectedColor: chipColor,
                  onSelected: (_) {
                    attendee.status = status;
                    onChanged();
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: attendee.note,
              minLines: 1,
              maxLines: 2,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '出勤备注',
                hintText: '例如：迟到、请假原因',
                prefixIcon: Icon(Icons.short_text),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({
    required this.label,
    required this.value,
    required this.onPressed,
  });

  final String label;
  final String value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    child: Row(
      children: [
        const Icon(Icons.schedule_outlined, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              Text(
                value,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AttendanceEmptyState extends StatelessWidget {
  const _AttendanceEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: colors.primary),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

String _memberInitial(String name) =>
    name.isEmpty ? '—' : String.fromCharCode(name.runes.first);
