import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/excel_import_service.dart';

class MembersPage extends StatefulWidget {
  const MembersPage({
    super.key,
    required this.repository,
    this.onCurrentSemesterChanged,
  });

  final LionRepository repository;
  final VoidCallback? onCurrentSemesterChanged;

  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  final TextEditingController _searchController = TextEditingController();
  List<Semester> _semesters = const [];
  List<Member> _members = const [];
  int? _semesterId;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reloadSemesters();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
      _members = selected == null
          ? const []
          : widget.repository.getMembers(selected);
    });
  }

  void _reloadMembers() {
    final id = _semesterId;
    setState(() {
      _members = id == null ? const [] : widget.repository.getMembers(id);
    });
  }

  Semester? get _selectedSemester {
    final id = _semesterId;
    if (id == null) return null;
    for (final semester in _semesters) {
      if (semester.id == id) return semester;
    }
    return null;
  }

  void _setSelectedSemesterAsCurrent() {
    final semester = _selectedSemester;
    if (semester == null || semester.isCurrent) return;
    try {
      widget.repository.setCurrentSemester(semester.id);
      _reloadSemesters(preferredSemesterId: semester.id);
      widget.onCurrentSemesterChanged?.call();
      _showMessage('已将“${semester.label}”设为全局当前学期。');
    } catch (error) {
      _showMessage('设置失败：$error');
    }
  }

  List<Member> get _visibleMembers {
    if (_query.isEmpty) return _members;
    final query = _query.toLowerCase();
    return _members
        .where((member) {
          return member.name.toLowerCase().contains(query) ||
              member.studentNo.toLowerCase().contains(query) ||
              member.grade.toLowerCase().contains(query) ||
              member.major.toLowerCase().contains(query) ||
              member.position.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _editMember([Member? member]) async {
    final semesterId = _semesterId;
    if (semesterId == null) return;
    final result = await showDialog<_MemberDraft>(
      context: context,
      builder: (context) => _MemberEditorDialog(
        member: member,
        people: widget.repository.getPeople(),
      ),
    );
    if (result == null || !mounted) return;
    try {
      if (member == null) {
        widget.repository.addMember(
          semesterId: semesterId,
          personId: result.personId,
          name: result.name,
          studentNo: result.studentNo,
          grade: result.grade,
          major: result.major,
          position: result.position,
          birthday: result.birthday,
          notes: result.notes,
          active: result.active,
        );
      } else {
        widget.repository.updateMember(
          Member(
            id: member.id,
            personId: result.personId ?? member.personId,
            semesterId: semesterId,
            studentNo: result.studentNo,
            name: result.name,
            grade: result.grade,
            major: result.major,
            position: result.position,
            birthday: result.birthday,
            notes: result.notes,
            active: result.active,
          ),
        );
      }
      _reloadMembers();
      _showMessage(member == null ? '成员已添加' : '成员信息已更新');
    } catch (error) {
      _showMessage('保存失败：$error');
    }
  }

  Future<void> _createSemester() async {
    final label = await showDialog<String>(
      context: context,
      builder: (context) => _CreateSemesterDialog(
        existingLabels: _semesters.map((semester) => semester.label).toList(),
      ),
    );
    if (label == null || !mounted) return;
    try {
      final semesterId = widget.repository.addSemester(label: label);
      _reloadSemesters(preferredSemesterId: semesterId);
      _showMessage('学期已创建，名册为空；可添加成员或手动复制其他学期名册。');
    } catch (error) {
      _showMessage('创建失败：$error');
    }
  }

  Future<void> _copyRoster() async {
    final destinationId = _semesterId;
    final sources = _semesters
        .where((item) => item.id != destinationId)
        .toList();
    if (destinationId == null || sources.isEmpty) return;
    final sourceId = await showDialog<int>(
      context: context,
      builder: (context) => _CopyRosterDialog(semesters: sources),
    );
    if (sourceId == null || !mounted) return;
    try {
      final copied = widget.repository.copyMemberRoster(
        fromSemesterId: sourceId,
        toSemesterId: destinationId,
      );
      _reloadMembers();
      _showMessage('已复制 $copied 位成员；目标学期中已有的成员保持不变');
    } catch (error) {
      _showMessage('复制失败：$error');
    }
  }

  Future<void> _downloadMemberTemplate() async {
    try {
      final data = await rootBundle.load(
        'assets/templates/member_roster_template.xlsx',
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final saved = await FilePicker.saveFile(
        fileName: '成员名册.xlsx',
        bytes: bytes,
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        dialogTitle: '保存成员名册模板',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      if (saved != null && mounted) {
        _showMessage('模板已保存到所选位置。');
      }
    } catch (error) {
      if (mounted) _showMessage('导出模板失败：$error');
    }
  }

  Future<void> _importRoster() async {
    final semesterId = _semesterId;
    if (semesterId == null) return;
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: '选择成员名册 XLSX',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      final result = const ExcelImportService().parseMembers(bytes);
      final semester = _semesters.firstWhere((item) => item.id == semesterId);
      final entries = _makeImportPreviewRows(
        result,
        widget.repository.getMembers(semesterId),
      );
      final confirmedRows = await showDialog<List<_MemberImportPreviewRow>>(
        context: context,
        builder: (context) => _MemberImportPreviewDialog(
          result: result,
          semesterLabel: semester.label,
          rows: entries,
        ),
      );
      if (confirmedRows == null || !mounted) return;
      _commitRosterImport(semesterId, confirmedRows);
    } catch (error) {
      if (mounted) _showMessage('导入成员名册失败：$error');
    }
  }

  List<_MemberImportPreviewRow> _makeImportPreviewRows(
    ExcelImportResult result,
    List<Member> existingMembers,
  ) {
    final seenWorkbookKeys = <String>{};
    return result.rows
        .map((row) {
          final fields = row.fields;
          final name = (fields['姓名'] ?? '').trim();
          final studentNo = _importField(row, '学号', preserveRaw: true).trim();
          if (name.isEmpty) {
            return _MemberImportPreviewRow(
              row: row,
              blockedReason: '姓名为空，无法导入。',
            );
          }

          final studentKey = _normalizeStudentNo(studentNo);
          final workbookKey = studentKey.isNotEmpty
              ? 'id:$studentKey'
              : 'name:${name.toLowerCase()}';
          if (!seenWorkbookKeys.add(workbookKey)) {
            return _MemberImportPreviewRow(
              row: row,
              blockedReason: studentKey.isNotEmpty
                  ? '文件内学号重复，已保留首次出现的记录。'
                  : '文件内姓名重复且无学号，已保留首次出现的记录。',
            );
          }

          final matches = existingMembers
              .where((member) {
                if (studentKey.isNotEmpty) {
                  return _normalizeStudentNo(member.studentNo) == studentKey;
                }
                return member.studentNo.trim().isEmpty &&
                    member.name.trim().toLowerCase() == name.toLowerCase();
              })
              .toList(growable: false);
          if (matches.length > 1) {
            return _MemberImportPreviewRow(
              row: row,
              blockedReason: '当前学期有多位成员匹配，需先手动整理名册。',
            );
          }
          if (matches.length == 1) {
            return _MemberImportPreviewRow(
              row: row,
              existingMember: matches.single,
              choice: _MemberImportChoice.skip,
            );
          }
          return _MemberImportPreviewRow(row: row);
        })
        .toList(growable: false);
  }

  String _normalizeStudentNo(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), '').toUpperCase();

  void _commitRosterImport(int semesterId, List<_MemberImportPreviewRow> rows) {
    var added = 0;
    var updated = 0;
    var skipped = 0;
    var failed = 0;
    for (final entry in rows) {
      final fields = entry.row.fields;
      try {
        switch (entry.choice) {
          case _MemberImportChoice.add:
            widget.repository.addMember(
              semesterId: semesterId,
              name: (fields['姓名'] ?? '').trim(),
              studentNo: _importField(entry.row, '学号', preserveRaw: true),
              grade: (fields['年级'] ?? '').trim(),
              major: (fields['专业'] ?? '').trim(),
              birthday: _importField(entry.row, '生日'),
              contact: _importField(entry.row, '联系方式', preserveRaw: true),
              position: (fields['职位'] ?? '').trim(),
            );
            added++;
            break;
          case _MemberImportChoice.update:
            final existing = entry.existingMember;
            if (existing == null) {
              skipped++;
              continue;
            }
            widget.repository.updateMember(
              Member(
                id: existing.id,
                personId: existing.personId,
                semesterId: semesterId,
                studentNo: _importField(entry.row, '学号', preserveRaw: true),
                name: (fields['姓名'] ?? '').trim(),
                grade: (fields['年级'] ?? '').trim(),
                major: (fields['专业'] ?? '').trim(),
                position: (fields['职位'] ?? '').trim(),
                birthday: _importField(entry.row, '生日'),
                contact: _importField(entry.row, '联系方式', preserveRaw: true),
                notes: existing.notes,
                active: existing.active,
              ),
            );
            updated++;
            break;
          case _MemberImportChoice.skip:
            skipped++;
            break;
        }
      } catch (_) {
        failed++;
      }
    }
    if (_semesterId == semesterId) _reloadMembers();
    _showMessage('导入完成：新增 $added，更新 $updated，跳过 $skipped，失败 $failed。');
  }

  String _importField(
    ExcelImportRow row,
    String field, {
    bool preserveRaw = false,
  }) {
    if (field == '生日' && row.numericFields.containsKey(field)) {
      return row.fields[field] ?? row.rawFields[field] ?? '';
    }
    if (preserveRaw) return row.rawFields[field] ?? row.fields[field] ?? '';
    return row.fields[field] ?? row.rawFields[field] ?? '';
  }

  Future<void> _showMemberCard(Member member) async {
    final history = widget.repository.getMemberSemesterHistory(member);
    final person = widget.repository.getPerson(member.personId);
    if (person == null) {
      _showMessage('找不到这位成员的长期档案，请检查数据库记录。');
      return;
    }
    final activities = widget.repository.getEventsForMemberIds(
      history.map((item) => item.id),
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _MemberProfileDialog(
        person: person,
        member: member,
        semesterHistory: history,
        semesters: _semesters,
        activities: activities,
      ),
    );
  }

  Future<void> _deactivateMember(Member member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从本学期名册停用？'),
        content: Text(
          '确定将“${member.name}”从本学期在册名单停用吗？长期个人档案、考勤和活动记录都会保留，可在编辑时重新启用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('停用'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      widget.repository.deactivateMember(member.id);
      _reloadMembers();
      _showMessage('成员已从本学期在册名册停用，历史记录保留');
    } catch (error) {
      _showMessage('停用失败：$error');
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
    final activeCount = _members.where((member) => member.active).length;
    final globalCurrentSemester = widget.repository.getCurrentSemester();
    final selectedSemester = _selectedSemester;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
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
                          Icons.groups_2_outlined,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '成员名册',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '名册按学期显示；同一成员的历年信息汇总在一张长期个人名片中',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      if (MediaQuery.sizeOf(context).width < 720) ...[
                        IconButton.filledTonal(
                          onPressed: _createSemester,
                          tooltip: '新建学期',
                          icon: const Icon(Icons.add_box_outlined),
                        ),
                        IconButton.filledTonal(
                          onPressed: _semesterId == null
                              ? null
                              : () => _editMember(),
                          tooltip: '添加成员',
                          icon: const Icon(Icons.person_add_alt_1),
                        ),
                      ] else ...[
                        FilledButton.tonalIcon(
                          onPressed: _createSemester,
                          icon: const Icon(Icons.add_box_outlined),
                          label: const Text('新建学期'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _semesterId == null
                              ? null
                              : () => _editMember(),
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('添加成员'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 22),
                  Card(
                    elevation: 0,
                    color: colors.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final selector = DropdownButtonFormField<int>(
                            value: _semesterId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '查看名册学期',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.calendar_month_outlined),
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
                                _members = widget.repository.getMembers(value);
                              });
                            },
                          );
                          final search = TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: '搜索姓名、学号、年级、专业或职位',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _query.isEmpty
                                  ? null
                                  : IconButton(
                                      onPressed: _searchController.clear,
                                      icon: const Icon(Icons.close),
                                      tooltip: '清除搜索',
                                    ),
                              border: const OutlineInputBorder(),
                            ),
                          );
                          final actions = Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Chip(
                                avatar: const Icon(
                                  Icons.flag_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  '全局当前：${globalCurrentSemester?.label ?? '未设置'}',
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed:
                                    selectedSemester == null ||
                                        selectedSemester.isCurrent
                                    ? null
                                    : _setSelectedSemesterAsCurrent,
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text('设为当前学期'),
                              ),
                              FilledButton.icon(
                                onPressed: _semesterId == null
                                    ? null
                                    : _importRoster,
                                icon: const Icon(Icons.upload_file_outlined),
                                label: const Text('导入 XLSX'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _downloadMemberTemplate,
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('下载成员模板'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _semesters.length < 2
                                    ? null
                                    : _copyRoster,
                                icon: const Icon(Icons.content_copy_outlined),
                                label: const Text('复制其他学期名册'),
                              ),
                              Chip(
                                avatar: const Icon(
                                  Icons.people_outline,
                                  size: 18,
                                ),
                                label: Text(
                                  '${_members.length} 人 · 在册 $activeCount 人',
                                ),
                              ),
                            ],
                          );
                          if (constraints.maxWidth < 900) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                selector,
                                const SizedBox(height: 12),
                                search,
                                const SizedBox(height: 12),
                                actions,
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  SizedBox(width: 250, child: selector),
                                  const SizedBox(width: 12),
                                  Expanded(child: search),
                                ],
                              ),
                              const SizedBox(height: 12),
                              actions,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(child: _buildRoster(colors)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoster(ColorScheme colors) {
    if (_semesters.isEmpty) {
      return _EmptyMembersState(
        icon: Icons.event_busy_outlined,
        title: '还没有学期',
        message: '请先在学期管理中建立学期，再添加成员名册。',
      );
    }
    final visible = _visibleMembers;
    if (visible.isEmpty) {
      return _EmptyMembersState(
        icon: _query.isEmpty ? Icons.person_add_alt : Icons.search_off,
        title: _query.isEmpty ? '这个学期还没有成员' : '没有找到匹配成员',
        message: _query.isEmpty ? '添加一位成员开始建立名册。' : '试试姓名、学号、年级、专业或职位的其他关键词。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: visible.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final member = visible[index];
        final meta = [
          member.studentNo,
          member.grade,
          member.major,
          member.position,
        ].where((value) => value.trim().isNotEmpty).join(' · ');
        return Card(
          elevation: 0,
          color: colors.surfaceContainerLow,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 7,
            ),
            onTap: () => _showMemberCard(member),
            leading: CircleAvatar(
              backgroundColor: member.active
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest,
              foregroundColor: member.active
                  ? colors.onPrimaryContainer
                  : colors.onSurfaceVariant,
              child: Text(_memberInitial(member.name)),
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    member.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(
                  label: member.active ? '在册' : '已停用',
                  active: member.active,
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                [
                  if (meta.isNotEmpty) meta,
                  if (member.notes.trim().isNotEmpty) member.notes,
                ].join('\n'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: Wrap(
              spacing: 2,
              children: [
                IconButton(
                  onPressed: () => _editMember(member),
                  tooltip: '编辑成员',
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  onPressed: () => _deactivateMember(member),
                  tooltip: '从本学期名册停用',
                  icon: Icon(Icons.person_off_outlined, color: colors.error),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _MemberImportChoice { add, update, skip }

class _MemberImportPreviewRow {
  _MemberImportPreviewRow({
    required this.row,
    this.existingMember,
    this.blockedReason,
    _MemberImportChoice? choice,
  }) : choice = blockedReason != null
           ? _MemberImportChoice.skip
           : choice ?? _MemberImportChoice.add;

  final ExcelImportRow row;
  final Member? existingMember;
  final String? blockedReason;
  _MemberImportChoice choice;
}

class _MemberImportPreviewDialog extends StatefulWidget {
  const _MemberImportPreviewDialog({
    required this.result,
    required this.semesterLabel,
    required this.rows,
  });

  final ExcelImportResult result;
  final String semesterLabel;
  final List<_MemberImportPreviewRow> rows;

  @override
  State<_MemberImportPreviewDialog> createState() =>
      _MemberImportPreviewDialogState();
}

class _MemberImportPreviewDialogState
    extends State<_MemberImportPreviewDialog> {
  int get _addCount => widget.rows
      .where(
        (entry) =>
            entry.blockedReason == null &&
            entry.existingMember == null &&
            entry.choice == _MemberImportChoice.add,
      )
      .length;

  int get _updateCount => widget.rows
      .where(
        (entry) =>
            entry.blockedReason == null &&
            entry.existingMember != null &&
            entry.choice == _MemberImportChoice.update,
      )
      .length;

  int get _duplicateCount =>
      widget.rows.where((entry) => entry.existingMember != null).length;

  int get _skipCount => widget.rows.length - _addCount - _updateCount;

  bool get _canImport =>
      !widget.result.hasErrors && _addCount + _updateCount > 0;

  String _field(ExcelImportRow row, String label, {bool preserveRaw = false}) {
    final fields = preserveRaw ? row.rawFields : row.fields;
    return fields[label] ?? row.fields[label] ?? '';
  }

  String _choiceLabel(_MemberImportChoice choice) => switch (choice) {
    _MemberImportChoice.add => '新增',
    _MemberImportChoice.update => '更新已有成员',
    _MemberImportChoice.skip => '跳过',
  };

  Color _choiceColor(ColorScheme colors, _MemberImportChoice choice) =>
      switch (choice) {
        _MemberImportChoice.add => colors.tertiaryContainer,
        _MemberImportChoice.update => colors.primaryContainer,
        _MemberImportChoice.skip => colors.surfaceContainerHighest,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final warnings = widget.result.diagnostics
        .where(
          (diagnostic) =>
              diagnostic.severity == ExcelImportDiagnosticSeverity.warning,
        )
        .toList(growable: false);
    return AlertDialog(
      title: const Text('导入成员名册预览'),
      content: SizedBox(
        width: 880,
        height: MediaQuery.sizeOf(context).height * 0.68,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '目标学期：${widget.semesterLabel} · 工作表：${widget.result.sheetName}',
            ),
            const SizedBox(height: 4),
            Text(
              '读取学号、生日和联系方式的单元格内容，不读取字体加粗等格式。'
              '学号和联系方式按原文读取；数值日期会转换成日期文本。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Chip(label: Text('新增 $_addCount')),
                Chip(label: Text('已有匹配 $_duplicateCount')),
                Chip(label: Text('更新 $_updateCount')),
                Chip(label: Text('跳过 $_skipCount')),
              ],
            ),
            if (widget.result.hasErrors)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: widget.result.diagnostics
                      .where(
                        (diagnostic) =>
                            diagnostic.severity ==
                            ExcelImportDiagnosticSeverity.error,
                      )
                      .map((diagnostic) => Text(diagnostic.message))
                      .toList(),
                ),
              )
            else if (warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  warnings
                      .take(4)
                      .map((diagnostic) => diagnostic.message)
                      .join('\n'),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            Expanded(
              child: widget.rows.isEmpty
                  ? Center(
                      child: Text(
                        '工作表中没有可预览的成员行。',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: widget.rows.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _buildRowCard(context, colors, widget.rows[index]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _canImport
              ? () => Navigator.pop(context, widget.rows)
              : null,
          icon: const Icon(Icons.file_download_done_outlined),
          label: Text('确认导入（新增 $_addCount · 更新 $_updateCount）'),
        ),
      ],
    );
  }

  Widget _buildRowCard(
    BuildContext context,
    ColorScheme colors,
    _MemberImportPreviewRow entry,
  ) {
    final row = entry.row;
    final name = _field(row, '姓名').trim();
    final studentNo = _field(row, '学号', preserveRaw: true);
    final contact = _field(row, '联系方式', preserveRaw: true);
    final details = [
      '学号：${studentNo.trim().isEmpty ? '未填写' : studentNo}',
      '年级：${_field(row, '年级').trim().ifEmpty('未填写')}',
      '专业：${_field(row, '专业').trim().ifEmpty('未填写')}',
      '生日：${_field(row, '生日').trim().ifEmpty('未填写')}',
      '联系方式：${contact.trim().isEmpty ? '未填写' : contact}',
      '职位：${_field(row, '职位').trim().ifEmpty('未填写')}',
    ].join('\n');
    final statusColor = entry.blockedReason != null
        ? colors.errorContainer
        : _choiceColor(colors, entry.choice);
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '第 ${row.rowNumber} 行 · ${name.isEmpty ? '（无姓名）' : name}',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (entry.blockedReason == null)
                  DropdownButton<_MemberImportChoice>(
                    value: entry.choice,
                    items:
                        (entry.existingMember == null
                                ? const [
                                    _MemberImportChoice.add,
                                    _MemberImportChoice.skip,
                                  ]
                                : const [
                                    _MemberImportChoice.update,
                                    _MemberImportChoice.skip,
                                  ])
                            .map(
                              (choice) => DropdownMenuItem(
                                value: choice,
                                child: Text(_choiceLabel(choice)),
                              ),
                            )
                            .toList(),
                    onChanged: (choice) {
                      if (choice == null) return;
                      setState(() => entry.choice = choice);
                    },
                  )
                else
                  Chip(
                    backgroundColor: statusColor,
                    label: const Text('不可导入'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (entry.existingMember != null && entry.blockedReason == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '当前学期已有：${entry.existingMember!.name} · ${entry.existingMember!.studentNo.isEmpty ? '无学号' : entry.existingMember!.studentNo}。请选择更新或跳过。',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.primary),
                ),
              ),
            if (entry.blockedReason != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  entry.blockedReason!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.error),
                ),
              ),
            Text(details, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _MemberDraft {
  const _MemberDraft({
    required this.personId,
    required this.name,
    required this.studentNo,
    required this.grade,
    required this.major,
    required this.position,
    required this.birthday,
    required this.notes,
    required this.active,
  });

  final int? personId;
  final String name;
  final String studentNo;
  final String grade;
  final String major;
  final String position;
  final String birthday;
  final String notes;
  final bool active;
}

class _MemberEditorDialog extends StatefulWidget {
  const _MemberEditorDialog({required this.people, this.member});

  final List<PersonProfile> people;
  final Member? member;

  @override
  State<_MemberEditorDialog> createState() => _MemberEditorDialogState();
}

class _MemberEditorDialogState extends State<_MemberEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _studentNo;
  late final TextEditingController _grade;
  late final TextEditingController _major;
  late final TextEditingController _position;
  late final TextEditingController _birthday;
  late final TextEditingController _notes;
  late int? _personId;
  late bool _active;

  @override
  void initState() {
    super.initState();
    final member = widget.member;
    _personId = member?.personId;
    _name = TextEditingController(text: member?.name ?? '');
    _studentNo = TextEditingController(text: member?.studentNo ?? '');
    _grade = TextEditingController(text: member?.grade ?? '');
    _major = TextEditingController(text: member?.major ?? '');
    _position = TextEditingController(text: member?.position ?? '');
    _birthday = TextEditingController(text: member?.birthday ?? '');
    _notes = TextEditingController(text: member?.notes ?? '');
    _active = member?.active ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _studentNo.dispose();
    _grade.dispose();
    _major.dispose();
    _position.dispose();
    _birthday.dispose();
    _notes.dispose();
    super.dispose();
  }

  String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final parsed = DateTime.tryParse(_birthday.text.trim());
    final parsedInitial = parsed ?? DateTime(now.year - 15, now.month, now.day);
    final initial = parsedInitial.isAfter(now) ? now : parsedInitial;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: '选择出生日期',
    );
    if (picked != null) _birthday.text = _isoDate(picked);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _MemberDraft(
        personId: _personId,
        name: _name.text.trim(),
        studentNo: _studentNo.text.trim(),
        grade: _grade.text.trim(),
        major: _major.text.trim(),
        position: _position.text.trim(),
        birthday: _birthday.text.trim(),
        notes: _notes.text.trim(),
        active: _active,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.member == null ? '添加成员' : '编辑成员'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.people.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DropdownButtonFormField<int?>(
                      value: _personId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '长期个人档案',
                        prefixIcon: Icon(Icons.folder_shared_outlined),
                      ),
                      items: [
                        if (widget.member == null)
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('新建个人档案'),
                          ),
                        ...widget.people.map(
                          (person) => DropdownMenuItem<int?>(
                            value: person.id,
                            child: Text(
                              '${person.displayName} · ${person.birthday.isEmpty ? '生日未填' : person.birthday} · 档案#${person.id}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setState(() => _personId = value);
                        if (value == null) return;
                        final selected = widget.people.firstWhere(
                          (person) => person.id == value,
                        );
                        _name.text = selected.displayName;
                        _birthday.text = selected.birthday;
                      },
                    ),
                  ),
                if (widget.people.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '同一人跨学期请选择同一个档案；学号、年级、专业和职位仍按当前学期填写。资料缺少自动匹配线索时，也可在这里手动关联。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '姓名 *',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入姓名' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _studentNo,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '学号',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _grade,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: '年级'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _major,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: '专业'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _position,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '职位',
                    prefixIcon: Icon(Icons.work_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _birthday,
                  decoration: InputDecoration(
                    labelText: '出生日期',
                    hintText: 'YYYY-MM-DD',
                    prefixIcon: const Icon(Icons.cake_outlined),
                    suffixIcon: IconButton(
                      onPressed: _pickBirthday,
                      tooltip: '选择日期',
                      icon: const Icon(Icons.calendar_today_outlined),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.notes_outlined),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('列入在册名册'),
                  subtitle: const Text('停用成员仍保留在该学期的历史资料中'),
                  value: _active,
                  onChanged: (value) => setState(() => _active = value),
                ),
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
        FilledButton(onPressed: _save, child: const Text('保存成员')),
      ],
    );
  }
}

class _MemberProfileDialog extends StatelessWidget {
  const _MemberProfileDialog({
    required this.person,
    required this.member,
    required this.semesterHistory,
    required this.semesters,
    required this.activities,
  });

  final PersonProfile person;
  final Member member;
  final List<Member> semesterHistory;
  final List<Semester> semesters;
  final List<EventModel> activities;

  String _semesterLabel(int semesterId) {
    for (final semester in semesters) {
      if (semester.id == semesterId) return semester.label;
    }
    return '学期 $semesterId';
  }

  String _dateLabel(String value) {
    final date = DateTime.tryParse(value);
    if (date == null) return value.trim().isEmpty ? '未记录' : value;
    return '${date.year}年${date.month}月${date.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          CircleAvatar(
            backgroundColor: colors.primaryContainer,
            foregroundColor: colors.onPrimaryContainer,
            child: Text(_memberInitial(person.displayName)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(person.displayName),
                Text(
                  member.active ? '长期个人档案 · 本学期在册' : '长期个人档案 · 本学期已停用',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 580,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.68,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _ProfileSectionHeader(title: '基本信息'),
                _ProfileInfoRow(label: '姓名', value: person.displayName),
                _ProfileInfoRow(
                  label: '生日',
                  value: _dateLabel(person.birthday),
                ),
                const _ProfileSectionHeader(title: '各学期信息'),
                if (semesterHistory.isEmpty)
                  const _ProfileEmptyText(text: '没有找到其他学期的成员记录。')
                else
                  ...semesterHistory.map((record) {
                    return Card(
                      elevation: 0,
                      color: colors.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.calendar_month_outlined,
                                  size: 18,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _semesterLabel(record.semesterId),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (!record.active)
                                  const Chip(
                                    label: Text('已停用'),
                                    visualDensity: VisualDensity.compact,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _ProfileValueChip(
                                  label: '学号',
                                  value: record.studentNo,
                                ),
                                _ProfileValueChip(
                                  label: '姓名',
                                  value: record.name,
                                ),
                                _ProfileValueChip(
                                  label: '年级',
                                  value: record.grade,
                                ),
                                _ProfileValueChip(
                                  label: '专业',
                                  value: record.major,
                                ),
                                _ProfileValueChip(
                                  label: '职位',
                                  value: record.position,
                                ),
                              ],
                            ),
                            if (record.notes.trim().isNotEmpty)
                              _ProfileInfoRow(
                                label: '当学期备注',
                                value: record.notes,
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                _ProfileSectionHeader(title: '参与活动（${activities.length}）'),
                if (activities.isEmpty)
                  const _ProfileEmptyText(text: '还没有关联的活动记录。')
                else
                  ...activities.map((event) {
                    final details = [
                      _dateLabel(event.eventDate),
                      if (event.location.trim().isNotEmpty) event.location,
                      if (event.summary.trim().isNotEmpty) event.summary,
                    ].join(' · ');
                    return Card(
                      elevation: 0,
                      color: colors.surfaceContainerLow,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colors.tertiaryContainer,
                          foregroundColor: colors.onTertiaryContainer,
                          child: const Icon(Icons.event_outlined),
                        ),
                        title: Text(event.title),
                        subtitle: details.isEmpty
                            ? null
                            : Text(
                                details,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _ProfileSectionHeader extends StatelessWidget {
  const _ProfileSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _ProfileInfoRow extends StatelessWidget {
  const _ProfileInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value.trim().isEmpty ? '未填写' : value)),
        ],
      ),
    );
  }
}

class _ProfileValueChip extends StatelessWidget {
  const _ProfileValueChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: const Icon(Icons.label_outline, size: 16),
    label: Text('$label：${value.trim().isEmpty ? '未填写' : value}'),
    visualDensity: VisualDensity.compact,
  );
}

class _ProfileEmptyText extends StatelessWidget {
  const _ProfileEmptyText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _CreateSemesterDialog extends StatefulWidget {
  const _CreateSemesterDialog({required this.existingLabels});

  final List<String> existingLabels;

  @override
  State<_CreateSemesterDialog> createState() => _CreateSemesterDialogState();
}

class _CreateSemesterDialogState extends State<_CreateSemesterDialog> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  String? _validateLabel(String? value) {
    final label = (value ?? '').trim();
    if (label.isEmpty) return '请输入学期名称';
    final duplicate = widget.existingLabels.any(
      (existing) => existing.trim().toLowerCase() == label.toLowerCase(),
    );
    if (duplicate) return '这个学期名称已存在';
    return null;
  }

  void _create() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _labelController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建学期'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _labelController,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _create(),
                decoration: const InputDecoration(
                  labelText: '学期名称',
                  hintText: '例如：2025学年第1学期',
                  prefixIcon: Icon(Icons.calendar_month_outlined),
                ),
                validator: _validateLabel,
              ),
              const SizedBox(height: 12),
              Text(
                '创建后会自动选中该学期。新学期名册默认为空，可稍后手动添加或复制其他学期名册。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _create, child: const Text('创建学期')),
      ],
    );
  }
}

class _CopyRosterDialog extends StatefulWidget {
  const _CopyRosterDialog({required this.semesters});

  final List<Semester> semesters;

  @override
  State<_CopyRosterDialog> createState() => _CopyRosterDialogState();
}

class _CopyRosterDialogState extends State<_CopyRosterDialog> {
  int? _sourceId;

  @override
  void initState() {
    super.initState();
    _sourceId = widget.semesters.first.id;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('复制学期名册'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('选择来源学期。成员资料会复制到当前学期；已存在的成员会跳过。'),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            value: _sourceId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '来源学期',
              border: OutlineInputBorder(),
            ),
            items: widget.semesters
                .map(
                  (semester) => DropdownMenuItem(
                    value: semester.id,
                    child: Text(semester.label),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => _sourceId = value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _sourceId == null
              ? null
              : () => Navigator.pop(context, _sourceId),
          icon: const Icon(Icons.content_copy_outlined),
          label: const Text('复制名册'),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active
            ? colors.secondaryContainer
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: active
                ? colors.onSecondaryContainer
                : colors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _EmptyMembersState extends StatelessWidget {
  const _EmptyMembersState({
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
