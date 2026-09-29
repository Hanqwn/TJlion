import 'dart:io';

import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/media_store.dart';
import 'document_viewer.dart';
import 'media_viewer.dart';

class DailyTrainingPage extends StatefulWidget {
  const DailyTrainingPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<DailyTrainingPage> createState() => _DailyTrainingPageState();
}

class _DailyTrainingPageState extends State<DailyTrainingPage> {
  late final MediaStore _mediaStore;
  final Map<String, MediaFileRef> _uncommittedMedia = {};
  List<Semester> _semesters = const [];
  List<AttendanceSession> _sessions = const [];
  int? _semesterId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _mediaStore = MediaStore(
      supportDirectory: widget.repository.supportDirectory,
    );
    _reloadSemesters();
  }

  void _reloadSemesters({int? preferredSemesterId}) {
    final semesters = widget.repository.getSemesters();
    final preferred = preferredSemesterId ?? _semesterId;
    final selected = semesters.any((semester) => semester.id == preferred)
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

  String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<void> _createTraining() async {
    if (_semesterId == null) {
      _message('请先创建或选择学期');
      return;
    }
    await _openEditor();
  }

  Future<void> _editTraining(AttendanceSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开始编辑训练日常？'),
        content: Text(
          '将编辑 ${session.sessionDate} ${session.startTime}–${session.endTime} 的训练记录。\n\n'
          '确认后可修改笔记、出勤情况和附件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始编辑'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _openEditor(session: session);
  }

  Future<void> _openEditor({AttendanceSession? session}) async {
    final semesterId = session?.semesterId ?? _semesterId;
    if (semesterId == null) return;
    await _discardUncommittedMedia(preserveLinked: true);
    final draft = await showDialog<_DailyTrainingDraft>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DailyTrainingEditorDialog(
        repository: widget.repository,
        mediaStore: _mediaStore,
        semesterId: semesterId,
        session: session,
        onMediaImported: (asset) => _uncommittedMedia[asset.mediaKey] = asset,
        onNewMediaRemoved: (asset) async {
          _uncommittedMedia.remove(asset.mediaKey);
          await _mediaStore.removeAsset(asset.mediaKey);
        },
      ),
    );
    if (!mounted) {
      await _discardUncommittedMedia(preserveLinked: true);
      return;
    }
    if (draft == null) {
      await _discardUncommittedMedia();
      return;
    }
    await _saveDraft(draft, semesterId, session);
  }

  Future<void> _discardUncommittedMedia({bool preserveLinked = false}) async {
    final pending = _uncommittedMedia.values.toList(growable: false);
    _uncommittedMedia.clear();
    final linkedKeys = preserveLinked
        ? widget.repository
              .getMediaAssets()
              .map((asset) => asset.mediaKey)
              .toSet()
        : const <String>{};
    for (final asset in pending) {
      if (linkedKeys.contains(asset.mediaKey)) continue;
      try {
        await _mediaStore.removeAsset(asset.mediaKey);
      } on FileSystemException {
        // A missing temporary attachment is already discarded.
      }
    }
  }

  Future<void> _saveDraft(
    _DailyTrainingDraft draft,
    int semesterId,
    AttendanceSession? existing,
  ) async {
    setState(() => _saving = true);
    try {
      final sessionId = existing == null
          ? widget.repository.addAttendanceSession(
              semesterId: semesterId,
              sessionDate: _isoDate(draft.date),
              startTime: draft.startTime,
              endTime: draft.endTime,
              title: draft.title,
              notes: draft.notes,
              initializePendingRecords: true,
            )
          : existing.id;

      if (existing != null) {
        widget.repository.updateAttendanceSession(
          AttendanceSession(
            id: existing.id,
            semesterId: existing.semesterId,
            sessionDate: _isoDate(draft.date),
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

      final previousAssets = existing == null
          ? const <MediaAssetModel>[]
          : widget.repository.getMediaAssets(
              ownerType: 'training_session',
              ownerId: sessionId,
            );
      final previousByKey = {
        for (final asset in previousAssets) asset.mediaKey: asset,
      };
      final selectedKeys = draft.attachments
          .map((asset) => asset.mediaKey)
          .toSet();
      for (final asset in draft.attachments) {
        if (previousByKey.containsKey(asset.mediaKey)) continue;
        widget.repository.putMediaAssetMetadata(
          mediaKey: asset.mediaKey,
          relativePath: asset.relativePath,
          ownerType: 'training_session',
          ownerId: sessionId,
          role: 'daily_training_attachment',
          title: asset.title,
          fileName: asset.fileName,
          mimeType: asset.mimeType,
          fileSize: asset.fileSize,
        );
      }
      for (final asset in previousAssets) {
        if (selectedKeys.contains(asset.mediaKey)) continue;
        await widget.repository.deleteMediaAsset(asset.id);
        await _mediaStore.removeAsset(asset.mediaKey);
      }

      _uncommittedMedia.clear();
      if (!mounted) return;
      setState(() {
        _semesterId = semesterId;
        _sessions = widget.repository.getAttendanceSessions(semesterId);
      });
      _message(existing == null ? '训练日常已保存' : '训练日常已更新');
    } catch (error) {
      await _discardUncommittedMedia(preserveLinked: true);
      if (mounted) {
        setState(() {
          _sessions = widget.repository.getAttendanceSessions(semesterId);
        });
        _message('保存失败：$error');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openAttachment(MediaAssetModel asset) async {
    final title = asset.title.isEmpty ? asset.fileName : asset.title;
    final isDocument =
        asset.fileName.toLowerCase().endsWith('.pdf') ||
        asset.fileName.toLowerCase().endsWith('.docx');
    if (isDocument) {
      final file = await _mediaStore.resolveFile(asset.mediaKey);
      if (!mounted) return;
      if (file == null) {
        _message('本机找不到这个附件文件');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => DocumentViewer(
          file: file,
          title: title,
          fileName: asset.fileName,
          mimeType: asset.mimeType,
        ),
      );
      return;
    }
    await showMediaViewer(
      context: context,
      mediaStore: _mediaStore,
      asset: asset,
    );
  }

  void _message(String message) {
    if (!mounted) return;
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
                          Icons.edit_calendar_outlined,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '训练日常',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '记录每次训练、出勤和现场附件',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      if (MediaQuery.sizeOf(context).width < 560)
                        IconButton.filledTonal(
                          onPressed: _saving ? null : _createTraining,
                          tooltip: '记录训练日常',
                          icon: const Icon(Icons.add),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _saving ? null : _createTraining,
                          icon: const Icon(Icons.add),
                          label: const Text('记录训练日常'),
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
                                labelText: '当前学期',
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
                              onChanged: _saving
                                  ? null
                                  : (value) {
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
                            label: Text('${_sessions.length} 次训练'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(child: _buildTrainingList(colors)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrainingList(ColorScheme colors) {
    if (_semesters.isEmpty) {
      return const _DailyEmptyState(
        icon: Icons.event_busy_outlined,
        title: '还没有学期',
        message: '请先创建学期和成员名册，再记录训练日常。',
      );
    }
    if (_sessions.isEmpty) {
      return _DailyEmptyState(
        icon: Icons.edit_calendar_outlined,
        title: '这个学期还没有训练日常',
        message: '记录训练日期、出勤情况、笔记和附件。',
        action: FilledButton.icon(
          onPressed: _createTraining,
          icon: const Icon(Icons.add),
          label: const Text('记录训练日常'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _sessions.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _DailyTrainingCard(
        session: _sessions[index],
        repository: widget.repository,
        onEdit: () => _editTraining(_sessions[index]),
        onOpenAttachment: _openAttachment,
      ),
    );
  }
}

class _DailyTrainingCard extends StatelessWidget {
  const _DailyTrainingCard({
    required this.session,
    required this.repository,
    required this.onEdit,
    required this.onOpenAttachment,
  });

  final AttendanceSession session;
  final LionRepository repository;
  final VoidCallback onEdit;
  final ValueChanged<MediaAssetModel> onOpenAttachment;

  String _dateLabel() {
    final date = DateTime.tryParse(session.sessionDate);
    if (date == null) return session.sessionDate;
    final weekday = const [
      '',
      '周一',
      '周二',
      '周三',
      '周四',
      '周五',
      '周六',
      '周日',
    ][date.weekday];
    return '${date.year}年${date.month}月${date.day}日 · $weekday';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final records = repository.getAttendanceRecords(session.id);
    final assets = repository.getMediaAssets(
      ownerType: 'training_session',
      ownerId: session.id,
    );
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
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
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
                        _dateLabel(),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${session.startTime}–${session.endTime}  ·  ${session.title}',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: onEdit,
                  tooltip: '编辑训练日常',
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            if (session.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(session.notes, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _DailyCountPill(
                  label: '出席 $present',
                  background: colors.tertiaryContainer,
                  foreground: colors.onTertiaryContainer,
                ),
                _DailyCountPill(
                  label: '缺席 $absent',
                  background: colors.errorContainer,
                  foreground: colors.onErrorContainer,
                ),
                _DailyCountPill(
                  label: '待确认 $pending',
                  background: colors.surfaceContainerHighest,
                  foreground: colors.onSurfaceVariant,
                ),
                _DailyCountPill(
                  label: '附件 ${assets.length}',
                  background: colors.secondaryContainer,
                  foreground: colors.onSecondaryContainer,
                ),
              ],
            ),
            if (assets.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: assets.take(5).map((asset) {
                  return ActionChip(
                    avatar: Icon(_attachmentIcon(asset.mimeType), size: 17),
                    label: Text(
                      asset.fileName,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => onOpenAttachment(asset),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('查看并编辑'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyTrainingDraft {
  const _DailyTrainingDraft({
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.title,
    required this.notes,
    required this.attendees,
    required this.attachments,
  });

  final DateTime date;
  final String startTime;
  final String endTime;
  final String title;
  final String notes;
  final List<_DailyAttendeeDraft> attendees;
  final List<MediaFileRef> attachments;
}

class _DailyAttendeeDraft {
  const _DailyAttendeeDraft({
    required this.member,
    required this.status,
    required this.note,
  });

  final Member member;
  final AttendanceStatus status;
  final String note;
}

class _DailyTrainingEditorDialog extends StatefulWidget {
  const _DailyTrainingEditorDialog({
    required this.repository,
    required this.mediaStore,
    required this.semesterId,
    required this.onMediaImported,
    required this.onNewMediaRemoved,
    this.session,
  });

  final LionRepository repository;
  final MediaStore mediaStore;
  final int semesterId;
  final AttendanceSession? session;
  final ValueChanged<MediaFileRef> onMediaImported;
  final Future<void> Function(MediaFileRef) onNewMediaRemoved;

  @override
  State<_DailyTrainingEditorDialog> createState() =>
      _DailyTrainingEditorDialogState();
}

class _DailyTrainingEditorDialogState
    extends State<_DailyTrainingEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _notes;
  late DateTime _date;
  late String _startTime;
  late String _endTime;
  late final List<_MutableDailyAttendee> _attendees;
  late final List<_MutableDailyAttachment> _attachments;

  bool get _isEditing => widget.session != null;

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    final parsedDate = DateTime.tryParse(session?.sessionDate ?? '');
    _date = parsedDate == null
        ? _dateOnly(DateTime.now())
        : _dateOnly(parsedDate);
    _startTime =
        session?.startTime ??
        (_date.weekday == DateTime.sunday ? '09:00' : '18:00');
    _endTime =
        session?.endTime ??
        (_date.weekday == DateTime.sunday ? '11:00' : '20:00');
    _notes = TextEditingController(text: session?.notes ?? '');

    final activeMembers = widget.repository.getMembers(
      widget.semesterId,
      activeOnly: true,
    );
    final records = session == null
        ? const <AttendanceRecord>[]
        : widget.repository.getAttendanceRecords(session.id);
    final membersById = {for (final member in activeMembers) member.id: member};
    for (final record in records) {
      final member = widget.repository.getMember(record.memberId);
      if (member != null) membersById[member.id] = member;
    }
    final recordByMember = {
      for (final record in records) record.memberId: record,
    };
    final members = membersById.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    _attendees = members.map((member) {
      final record = recordByMember[member.id];
      return _MutableDailyAttendee(
        member: member,
        status: record?.status ?? AttendanceStatus.pending,
        note: record?.note ?? '',
      );
    }).toList();

    final assets = session == null
        ? const <MediaAssetModel>[]
        : widget.repository.getMediaAssets(
            ownerType: 'training_session',
            ownerId: session.id,
          );
    _attachments = assets
        .map(
          (asset) => _MutableDailyAttachment(
            reference: _asFileRef(asset),
            isNew: false,
          ),
        )
        .toList();
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final attendee in _attendees) {
      attendee.dispose();
    }
    super.dispose();
  }

  static DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static MediaFileRef _asFileRef(MediaAssetModel asset) => MediaFileRef(
    mediaKey: asset.mediaKey,
    title: asset.title,
    fileName: asset.fileName,
    mimeType: asset.mimeType,
    fileSize: asset.fileSize,
    relativePath: asset.relativePath,
    createdAt: asset.createdAt,
  );

  String _isoDate(DateTime date) =>
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
    if (picked != null) {
      setState(() => _date = _dateOnly(picked));
    }
  }

  DateTime _nextWeekday(DateTime from, int weekday) {
    final daysToAdd = (weekday - from.weekday + 7) % 7;
    return DateTime(from.year, from.month, from.day + daysToAdd);
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

  Future<void> _pickMedia({required bool document}) async {
    try {
      final asset = document
          ? await widget.mediaStore.importDocumentFile(
              dialogTitle: '选择 PDF 或 DOCX 附件',
            )
          : await widget.mediaStore.pickMedia(dialogTitle: '选择图片、视频或音频附件');
      if (asset == null || !mounted) return;
      widget.onMediaImported(asset);
      setState(() {
        _attachments.add(
          _MutableDailyAttachment(reference: asset, isNew: true),
        );
      });
    } catch (error) {
      if (mounted) _message('添加附件失败：$error');
    }
  }

  Future<void> _removeAttachment(_MutableDailyAttachment attachment) async {
    if (attachment.isNew) {
      try {
        await widget.onNewMediaRemoved(attachment.reference);
      } catch (error) {
        _message('移除附件失败：$error');
        return;
      }
    }
    if (mounted) setState(() => _attachments.remove(attachment));
  }

  Future<void> _previewAttachment(MediaFileRef asset) async {
    if (asset.isSupportedDocument) {
      final file = await widget.mediaStore.resolveFile(asset.mediaKey);
      if (!mounted) return;
      if (file == null) {
        _message('本机找不到这个附件文件');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => DocumentViewer(
          file: file,
          title: asset.title.isEmpty ? asset.fileName : asset.title,
          fileName: asset.fileName,
          mimeType: asset.mimeType,
        ),
      );
      return;
    }
    await showMediaViewer(
      context: context,
      mediaStore: widget.mediaStore,
      asset: MediaAssetModel(
        id: 0,
        mediaKey: asset.mediaKey,
        ownerType: 'training_session',
        ownerId: widget.session?.id ?? 0,
        role: 'daily_training_attachment',
        title: asset.title,
        fileName: asset.fileName,
        mimeType: asset.mimeType,
        fileSize: asset.fileSize,
        relativePath: asset.relativePath,
        createdAt: asset.createdAt,
      ),
    );
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
    if (end.hour * 60 + end.minute <= start.hour * 60 + start.minute) {
      _message('结束时间必须晚于开始时间');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认保存训练日常'),
        content: Text(
          '训练日期：${_isoDate(_date)}\n'
          '出席：$_presentCount 人\n'
          '缺席：$_absentCount 人\n'
          '待确认：$_pendingCount 人\n'
          '附件：${_attachments.length} 个\n\n'
          '请核对日期、出勤人数和附件后保存。',
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
    Navigator.pop(
      context,
      _DailyTrainingDraft(
        date: _date,
        startTime: _startTime,
        endTime: _endTime,
        title: widget.session?.title ?? '训练日常',
        notes: _notes.text.trim(),
        attendees: _attendees
            .map(
              (item) => _DailyAttendeeDraft(
                member: item.member,
                status: item.status,
                note: item.note.text.trim(),
              ),
            )
            .toList(growable: false),
        attachments: _attachments
            .map((item) => item.reference)
            .toList(growable: false),
      ),
    );
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_isEditing ? '编辑训练日常' : '记录训练日常'),
      content: SizedBox(
        width: 760,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text('训练日期  ${_isoDate(_date)}'),
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
                      child: _DailyTimeButton(
                        label: '开始时间',
                        value: _startTime,
                        onPressed: () => _pickTime(start: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DailyTimeButton(
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
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '训练笔记（可选）',
                    hintText: '记录训练内容、问题或后续安排',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.notes_outlined),
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
                    child: const Text('这个学期还没有在册成员，请先添加成员名册。'),
                  )
                else
                  ..._attendees.map(
                    (attendee) => _DailyAttendeeEditor(
                      attendee: attendee,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '训练附件',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '${_attachments.length} 个',
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _pickMedia(document: false),
                      icon: const Icon(Icons.perm_media_outlined),
                      label: const Text('图片 / 视频 / 音频'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _pickMedia(document: true),
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('PDF / DOCX'),
                    ),
                  ],
                ),
                if (_attachments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '可添加现场照片、视频、录音或训练材料。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  )
                else ...[
                  const SizedBox(height: 8),
                  ..._attachments.map(
                    (attachment) => _DailyAttachmentRow(
                      attachment: attachment,
                      onOpen: () => _previewAttachment(attachment.reference),
                      onRemove: () => _removeAttachment(attachment),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_isEditing ? '保存修改' : '保存日常'),
        ),
      ],
    );
  }
}

class _MutableDailyAttendee {
  _MutableDailyAttendee({
    required this.member,
    required this.status,
    required String note,
  }) : note = TextEditingController(text: note);

  final Member member;
  AttendanceStatus status;
  final TextEditingController note;

  void dispose() => note.dispose();
}

class _MutableDailyAttachment {
  const _MutableDailyAttachment({required this.reference, required this.isNew});

  final MediaFileRef reference;
  final bool isNew;
}

class _DailyAttendeeEditor extends StatelessWidget {
  const _DailyAttendeeEditor({required this.attendee, required this.onChanged});

  final _MutableDailyAttendee attendee;
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
                  child: Text(_initial(member.name)),
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
                          if (member.position.trim().isNotEmpty)
                            member.position,
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
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: AttendanceStatus.values.map((status) {
                final selected = attendee.status == status;
                final selectedColor = switch (status) {
                  AttendanceStatus.pending => colors.surfaceContainerHighest,
                  AttendanceStatus.present => colors.tertiaryContainer,
                  AttendanceStatus.absent => colors.errorContainer,
                };
                return ChoiceChip(
                  label: Text(_statusLabel(status)),
                  selected: selected,
                  selectedColor: selectedColor,
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

class _DailyAttachmentRow extends StatelessWidget {
  const _DailyAttachmentRow({
    required this.attachment,
    required this.onOpen,
    required this.onRemove,
  });

  final _MutableDailyAttachment attachment;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final asset = attachment.reference;
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: colors.secondaryContainer,
          foregroundColor: colors.onSecondaryContainer,
          child: Icon(_attachmentIcon(asset.mimeType)),
        ),
        title: Text(
          asset.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${_formatBytes(asset.fileSize)}${attachment.isNew ? ' · 待保存' : ''}',
        ),
        onTap: onOpen,
        trailing: Wrap(
          spacing: 0,
          children: [
            IconButton(
              onPressed: onOpen,
              tooltip: '预览附件',
              icon: const Icon(Icons.open_in_new_outlined),
            ),
            IconButton(
              onPressed: onRemove,
              tooltip: '移除附件',
              icon: Icon(Icons.close, color: colors.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyTimeButton extends StatelessWidget {
  const _DailyTimeButton({
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

class _DailyCountPill extends StatelessWidget {
  const _DailyCountPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
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

class _DailyEmptyState extends StatelessWidget {
  const _DailyEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

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
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

String _initial(String name) =>
    name.isEmpty ? '—' : String.fromCharCode(name.runes.first);

IconData _attachmentIcon(String mimeType) {
  if (mimeType.startsWith('image/')) return Icons.image_outlined;
  if (mimeType.startsWith('video/')) return Icons.video_library_outlined;
  if (mimeType.startsWith('audio/')) return Icons.audiotrack_outlined;
  return Icons.description_outlined;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
