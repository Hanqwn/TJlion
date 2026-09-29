import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';

class MembersPage extends StatefulWidget {
  const MembersPage({super.key, required this.repository});

  final LionRepository repository;

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
      builder: (context) => _MemberEditorDialog(member: member),
    );
    if (result == null || !mounted) return;
    try {
      if (member == null) {
        widget.repository.addMember(
          semesterId: semesterId,
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

  Future<void> _showMemberCard(Member member) async {
    final history = widget.repository.getMemberSemesterHistory(member);
    final activities = widget.repository.getEventsForMemberIds(
      history.map((item) => item.id),
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _MemberProfileDialog(
        member: member,
        semesterHistory: history,
        semesters: _semesters,
        activities: activities,
      ),
    );
  }

  Future<void> _deleteMember(Member member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除成员？'),
        content: Text('确定删除“${member.name}”吗？关联的出勤记录也会一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      widget.repository.deleteMember(member.id);
      _reloadMembers();
      _showMessage('成员已删除');
    } catch (error) {
      _showMessage('删除失败：$error');
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
                              '按学期管理成员资料与在册状态',
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
                              labelText: '当前学期',
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
                              hintText: '搜索姓名、学号、年级或专业',
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
                          return Row(
                            children: [
                              SizedBox(width: 250, child: selector),
                              const SizedBox(width: 12),
                              Expanded(child: search),
                              const SizedBox(width: 12),
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
                  onPressed: () => _deleteMember(member),
                  tooltip: '删除成员',
                  icon: Icon(Icons.delete_outline, color: colors.error),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MemberDraft {
  const _MemberDraft({
    required this.name,
    required this.studentNo,
    required this.grade,
    required this.major,
    required this.position,
    required this.birthday,
    required this.notes,
    required this.active,
  });

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
  const _MemberEditorDialog({this.member});

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
  late bool _active;

  @override
  void initState() {
    super.initState();
    final member = widget.member;
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
    required this.member,
    required this.semesterHistory,
    required this.semesters,
    required this.activities,
  });

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
            child: Text(_memberInitial(member.name)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.name),
                Text(
                  member.active ? '在册成员名片' : '已停用成员名片',
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
                _ProfileInfoRow(label: '姓名', value: member.name),
                _ProfileInfoRow(
                  label: '学号',
                  value: member.studentNo.trim().isEmpty
                      ? '未填写'
                      : member.studentNo,
                ),
                _ProfileInfoRow(label: '年级', value: member.grade),
                _ProfileInfoRow(label: '专业', value: member.major),
                _ProfileInfoRow(
                  label: '生日',
                  value: _dateLabel(member.birthday),
                ),
                if (member.notes.trim().isNotEmpty)
                  _ProfileInfoRow(label: '备注', value: member.notes),
                const _ProfileSectionHeader(title: '各学期档案与职位'),
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
