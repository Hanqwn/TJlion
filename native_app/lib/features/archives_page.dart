import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';
import 'dashboard_page.dart' show AppSection;

class ArchivesPage extends StatefulWidget {
  const ArchivesPage({
    super.key,
    required this.repository,
    required this.onNavigate,
  });

  final LionRepository repository;
  final ValueChanged<AppSection> onNavigate;

  @override
  State<ArchivesPage> createState() => _ArchivesPageState();
}

class _ArchivesPageState extends State<ArchivesPage> {
  final TextEditingController _search = TextEditingController();
  List<PersonProfile> _profiles = const [];
  List<Member> _members = const [];
  List<Semester> _semesters = const [];
  List<EventModel> _events = const [];
  List<RecurringActivityModel> _activities = const [];
  int? _semesterFilter;
  String? _typeFilter;

  @override
  void initState() {
    super.initState();
    _reload();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    final repository = widget.repository;
    final semesters = repository.getSemesters();
    setState(() {
      _profiles = repository.getMemberProfiles();
      _semesters = semesters;
      _members = [
        for (final semester in semesters) ...repository.getMembers(semester.id),
      ];
      _events = repository.getEvents();
      _activities = repository.getRecurringActivities();
    });
  }

  List<PersonProfile> get _visibleProfiles {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _profiles;
    return _profiles
        .where((profile) {
          if (profile.displayName.toLowerCase().contains(query)) return true;
          return _members
              .where((member) => member.personId == profile.id)
              .any(
                (member) =>
                    member.studentNo.toLowerCase().contains(query) ||
                    member.grade.toLowerCase().contains(query) ||
                    member.major.toLowerCase().contains(query) ||
                    member.position.toLowerCase().contains(query) ||
                    (member.contact ?? '').toLowerCase().contains(query),
              );
        })
        .toList(growable: false);
  }

  Future<void> _openProfile(PersonProfile profile) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _MemberArchiveDialog(
        repository: widget.repository,
        profile: profile,
        semesters: _semesters,
        onChanged: _reload,
        onOpenEvents: () {
          Navigator.pop(dialogContext);
          widget.onNavigate(AppSection.events);
        },
      ),
    );
  }

  Future<void> _editActivity([RecurringActivityModel? activity]) async {
    final draft = await showDialog<_ActivityDraft>(
      context: context,
      builder: (context) => _ActivityEditor(activity: activity),
    );
    if (draft == null || !mounted) return;
    try {
      if (activity == null) {
        widget.repository.addRecurringActivity(
          title: draft.title,
          activityType: draft.type,
          description: draft.description,
          active: draft.active,
        );
      } else {
        widget.repository.updateRecurringActivity(
          RecurringActivityModel(
            id: activity.id,
            title: draft.title,
            activityType: draft.type,
            description: draft.description,
            active: draft.active,
            createdAt: activity.createdAt,
            updatedAt: activity.updatedAt,
          ),
        );
      }
      _reload();
      _message(activity == null ? '周期类别已添加' : '周期类别已更新');
    } catch (error) {
      _message('保存失败：$error');
    }
  }

  Future<void> _editEvent(EventModel event) async {
    final draft = await showDialog<_EventDraft>(
      context: context,
      builder: (context) => _EventEditor(
        event: event,
        semesters: _semesters,
        activities: _activities,
      ),
    );
    if (draft == null || !mounted) return;
    try {
      widget.repository.updateEvent(
        EventModel(
          id: event.id,
          title: draft.title,
          eventDate: draft.date,
          location: draft.location,
          summary: draft.summary,
          semesterId: event.semesterId,
          recurringActivityId: event.recurringActivityId,
          eventType: event.eventType,
          createdAt: event.createdAt,
          updatedAt: event.updatedAt,
        ),
      );
      RecurringActivityModel? selectedActivity;
      for (final activity in _activities) {
        if (activity.id == draft.activityId) {
          selectedActivity = activity;
          break;
        }
      }
      widget.repository.updateEventClassification(
        eventId: event.id,
        semesterId: draft.semesterId,
        recurringActivityId: draft.activityId,
        eventType: selectedActivity?.activityType ?? 'other',
      );
      _reload();
      _message('活动档案已更新');
    } catch (error) {
      _message('保存失败：$error');
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 560;
    final colors = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 28, 18, narrow ? 16 : 28, 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
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
                            '档案馆',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            '长期成员资料与周期活动历史。',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: '刷新档案',
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.people_outline), text: '成员档案'),
                    Tab(icon: Icon(Icons.history_edu_outlined), text: '活动档案'),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: TabBarView(children: [_membersTab(), _eventsTab()]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _membersTab() {
    final profiles = _visibleProfiles;
    return Column(
      children: [
        TextField(
          controller: _search,
          decoration: InputDecoration(
            hintText: '搜索姓名、学号、年级、专业或联系方式',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    onPressed: _search.clear,
                    icon: const Icon(Icons.close),
                  ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: profiles.isEmpty
              ? _ArchiveEmpty(
                  title: _profiles.isEmpty ? '还没有成员档案' : '没有匹配的成员',
                  message: _profiles.isEmpty
                      ? '建立成员名册后会汇总跨学期资料。'
                      : '换一个搜索关键词试试。',
                  icon: Icons.person_search_outlined,
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: profiles.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final profile = profiles[index];
                    final history = _members
                        .where((member) => member.personId == profile.id)
                        .toList(growable: false);
                    final latestNo = history.isEmpty
                        ? ''
                        : history.first.studentNo;
                    final count = history.length.toString();
                    final subtitle = latestNo.isEmpty
                        ? '$count 个学期'
                        : '学号 $latestNo · $count 个学期';
                    return Card(
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            profile.displayName.isEmpty
                                ? '—'
                                : profile.displayName.characters.first,
                          ),
                        ),
                        title: Text(
                          profile.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(subtitle),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _openProfile(profile),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _eventsTab() {
    final types = <String>{
      ..._activities.map((activity) => activity.activityType),
    }.toList()..sort();
    final activities = _activities
        .where(
          (activity) =>
              _typeFilter == null || activity.activityType == _typeFilter,
        )
        .toList(growable: false);
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int?>(
                initialValue: _semesterFilter,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '浏览学期',
                  prefixIcon: Icon(Icons.school_outlined),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('全部学期'),
                  ),
                  ..._semesters.map(
                    (semester) => DropdownMenuItem<int?>(
                      value: semester.id,
                      child: Text(semester.label),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _semesterFilter = value),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: () => _editActivity(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('周期类别'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('全部类别'),
                selected: _typeFilter == null,
                onSelected: (_) => setState(() => _typeFilter = null),
              ),
              ...types.map(
                (type) => ChoiceChip(
                  label: Text(_activityTypeLabel(type)),
                  selected: _typeFilter == type,
                  onSelected: (_) => setState(
                    () => _typeFilter = _typeFilter == type ? null : type,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              const _SectionTitle('周期活动类别'),
              ...activities.map((activity) {
                final events =
                    _events
                        .where(
                          (event) =>
                              event.recurringActivityId == activity.id &&
                              (_semesterFilter == null ||
                                  event.semesterId == _semesterFilter),
                        )
                        .toList()
                      ..sort(_compareEvents);
                return _ActivityTile(
                  activity: activity,
                  events: events,
                  semesterLabels: _semesterLabels,
                  onEditActivity: () => _editActivity(activity),
                  onEditEvent: _editEvent,
                  onOpenEvents: () => widget.onNavigate(AppSection.events),
                );
              }),
              const _SectionTitle('未归入周期类别'),
              ..._unlinkedEvents().entries.map(
                (entry) => _UnlinkedTile(
                  label: _activityTypeLabel(entry.key),
                  events: entry.value,
                  semesterLabels: _semesterLabels,
                  onEditEvent: _editEvent,
                  onOpenEvents: () => widget.onNavigate(AppSection.events),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Map<int, String> get _semesterLabels => {
    for (final semester in _semesters) semester.id: semester.label,
  };

  Map<String, List<EventModel>> _unlinkedEvents() {
    final groups = <String, List<EventModel>>{};
    for (final semesterGroup
        in widget.repository.getEventsGroupedBySemesterAndType().entries) {
      if (_semesterFilter != null && semesterGroup.key != _semesterFilter) {
        continue;
      }
      for (final typeGroup in semesterGroup.value.entries) {
        if (_typeFilter != null && typeGroup.key != _typeFilter) continue;
        final events = typeGroup.value.where(
          (event) => event.recurringActivityId == null,
        );
        for (final event in events) {
          final name = event.title.trim().isEmpty
              ? _activityTypeLabel(typeGroup.key)
              : event.title.trim();
          groups.putIfAbsent(name, () => []).add(event);
        }
      }
    }
    for (final events in groups.values) {
      events.sort(_compareEvents);
    }
    return groups;
  }
}

class _ProfileDraft {
  const _ProfileDraft({required this.name, required this.birthday});
  final String name;
  final String birthday;
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.profile});
  final PersonProfile profile;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _birthday;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile.displayName);
    _birthday = TextEditingController(text: widget.profile.birthday);
  }

  @override
  void dispose() {
    _name.dispose();
    _birthday.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _ProfileDraft(name: _name.text.trim(), birthday: _birthday.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑个人信息'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '姓名 *'),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? '请输入姓名' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _birthday,
              decoration: const InputDecoration(
                labelText: '生日',
                hintText: 'YYYY-MM-DD',
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
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class _MemberEditor extends StatefulWidget {
  const _MemberEditor({required this.member});
  final Member member;

  @override
  State<_MemberEditor> createState() => _MemberEditorState();
}

class _MemberEditorState extends State<_MemberEditor> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  late bool _active;

  @override
  void initState() {
    super.initState();
    final member = widget.member;
    _fields = {
      '姓名': TextEditingController(text: member.name),
      '学号': TextEditingController(text: member.studentNo),
      '年级': TextEditingController(text: member.grade),
      '专业': TextEditingController(text: member.major),
      '职位': TextEditingController(text: member.position),
      '生日': TextEditingController(text: member.birthday),
      '联系方式': TextEditingController(text: member.contact ?? ''),
      '备注': TextEditingController(text: member.notes),
    };
    _active = member.active;
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final member = widget.member;
    Navigator.pop(
      context,
      Member(
        id: member.id,
        personId: member.personId,
        semesterId: member.semesterId,
        name: _fields['姓名']!.text.trim(),
        studentNo: _fields['学号']!.text.trim(),
        grade: _fields['年级']!.text.trim(),
        major: _fields['专业']!.text.trim(),
        position: _fields['职位']!.text.trim(),
        birthday: _fields['生日']!.text.trim(),
        contact: _fields['联系方式']!.text.trim(),
        notes: _fields['备注']!.text.trim(),
        active: _active,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑学期名册资料'),
    content: SizedBox(
      width: 520,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._fields.entries.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextFormField(
                    controller: entry.value,
                    minLines: entry.key == '备注' ? 2 : 1,
                    maxLines: entry.key == '备注' ? 4 : 1,
                    decoration: InputDecoration(labelText: entry.key),
                    validator: entry.key == '姓名'
                        ? (value) =>
                              (value ?? '').trim().isEmpty ? '请输入姓名' : null
                        : null,
                  ),
                ),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('在册'),
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
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class _ActivityDraft {
  const _ActivityDraft({
    required this.title,
    required this.type,
    required this.description,
    required this.active,
  });
  final String title;
  final String type;
  final String description;
  final bool active;
}

class _ActivityEditor extends StatefulWidget {
  const _ActivityEditor({this.activity});
  final RecurringActivityModel? activity;

  @override
  State<_ActivityEditor> createState() => _ActivityEditorState();
}

class _ActivityEditorState extends State<_ActivityEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _type;
  late final TextEditingController _description;
  late bool _active;

  @override
  void initState() {
    super.initState();
    final activity = widget.activity;
    _title = TextEditingController(text: activity?.title ?? '');
    _type = TextEditingController(text: activity?.activityType ?? 'other');
    _description = TextEditingController(text: activity?.description ?? '');
    _active = activity?.active ?? true;
  }

  @override
  void dispose() {
    _title.dispose();
    _type.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _ActivityDraft(
        title: _title.text.trim(),
        type: _type.text.trim(),
        description: _description.text.trim(),
        active: _active,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.activity == null ? '新增周期类别' : '编辑周期类别'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: '类别名称 *'),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? '请输入类别名称' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _type,
              decoration: const InputDecoration(
                labelText: '活动类型 *',
                hintText: 'performance / competition / training',
              ),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? '请输入活动类型' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _description,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: '说明'),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用类别'),
              value: _active,
              onChanged: (value) => setState(() => _active = value),
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
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class _EventDraft {
  const _EventDraft({
    required this.title,
    required this.date,
    required this.location,
    required this.summary,
    required this.semesterId,
    required this.activityId,
  });
  final String title;
  final String date;
  final String location;
  final String summary;
  final int? semesterId;
  final int? activityId;
}

class _EventEditor extends StatefulWidget {
  const _EventEditor({
    required this.event,
    required this.semesters,
    required this.activities,
  });
  final EventModel event;
  final List<Semester> semesters;
  final List<RecurringActivityModel> activities;

  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _date;
  late final TextEditingController _location;
  late final TextEditingController _summary;
  int? _semesterId;
  int? _activityId;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.event.title);
    _date = TextEditingController(text: widget.event.eventDate);
    _location = TextEditingController(text: widget.event.location);
    _summary = TextEditingController(text: widget.event.summary);
    _semesterId = widget.event.semesterId;
    _activityId = widget.event.recurringActivityId;
  }

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    _location.dispose();
    _summary.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _EventDraft(
        title: _title.text.trim(),
        date: _date.text.trim(),
        location: _location.text.trim(),
        summary: _summary.text.trim(),
        semesterId: _semesterId,
        activityId: _activityId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑活动档案'),
    content: SizedBox(
      width: 500,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: '活动名称 *'),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? '请输入活动名称' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _date,
                decoration: const InputDecoration(
                  labelText: '日期',
                  hintText: 'YYYY-MM-DD',
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _location,
                decoration: const InputDecoration(labelText: '地点'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _summary,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(labelText: '摘要'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int?>(
                initialValue: _semesterId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '归档学期'),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('未归档学期'),
                  ),
                  ...widget.semesters.map(
                    (semester) => DropdownMenuItem<int?>(
                      value: semester.id,
                      child: Text(semester.label),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _semesterId = value),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int?>(
                initialValue: _activityId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '周期活动类别'),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('未归入周期类别'),
                  ),
                  ...widget.activities.map(
                    (activity) => DropdownMenuItem<int?>(
                      value: activity.id,
                      child: Text(activity.title),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _activityId = value),
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
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _ArchiveEmpty extends StatelessWidget {
  const _ArchiveEmpty({
    required this.title,
    required this.message,
    required this.icon,
  });
  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colors.primary),
            const SizedBox(height: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

String _archiveDate(String value) {
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return value;
  final year = parsed.year.toString();
  final month = parsed.month.toString().padLeft(2, '0');
  final day = parsed.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

int _compareEvents(EventModel left, EventModel right) {
  final comparison = right.eventDate.compareTo(left.eventDate);
  return comparison == 0 ? right.id.compareTo(left.id) : comparison;
}

String _activityTypeLabel(String type) {
  return switch (type) {
    'performance' => '演出',
    'competition' => '比赛',
    'training' => '训练',
    'other' => '其他',
    _ => type.isEmpty ? '未分类' : type,
  };
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.activity,
    required this.events,
    required this.semesterLabels,
    required this.onEditActivity,
    required this.onEditEvent,
    required this.onOpenEvents,
  });
  final RecurringActivityModel activity;
  final List<EventModel> events;
  final Map<int, String> semesterLabels;
  final VoidCallback onEditActivity;
  final ValueChanged<EventModel> onEditEvent;
  final VoidCallback onOpenEvents;

  @override
  Widget build(BuildContext context) {
    final type = _activityTypeLabel(activity.activityType);
    final count = events.length.toString();
    final status = activity.active ? '启用' : '已停用';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      child: ExpansionTile(
        leading: const Icon(Icons.repeat_rounded),
        title: Text(activity.title),
        subtitle: Text('$type · $count 次 · $status'),
        trailing: IconButton(
          tooltip: '编辑周期类别',
          onPressed: onEditActivity,
          icon: const Icon(Icons.edit_outlined),
        ),
        children: [
          if (activity.description.trim().isNotEmpty)
            ListTile(title: Text(activity.description)),
          if (events.isEmpty)
            const ListTile(title: Text('暂无活动记录'))
          else
            ...events.map(
              (event) => _EventArchiveRow(
                event: event,
                semesterLabel: _semesterLabel(event, semesterLabels),
                onEdit: () => onEditEvent(event),
                onOpen: onOpenEvents,
              ),
            ),
        ],
      ),
    );
  }
}

class _UnlinkedTile extends StatelessWidget {
  const _UnlinkedTile({
    required this.label,
    required this.events,
    required this.semesterLabels,
    required this.onEditEvent,
    required this.onOpenEvents,
  });
  final String label;
  final List<EventModel> events;
  final Map<int, String> semesterLabels;
  final ValueChanged<EventModel> onEditEvent;
  final VoidCallback onOpenEvents;

  @override
  Widget build(BuildContext context) {
    final count = events.length.toString();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      child: ExpansionTile(
        title: Text(label),
        subtitle: Text('$count 次活动'),
        children: events
            .map(
              (event) => _EventArchiveRow(
                event: event,
                semesterLabel: _semesterLabel(event, semesterLabels),
                onEdit: () => onEditEvent(event),
                onOpen: onOpenEvents,
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _EventArchiveRow extends StatelessWidget {
  const _EventArchiveRow({
    required this.event,
    required this.semesterLabel,
    required this.onEdit,
    required this.onOpen,
  });
  final EventModel event;
  final String semesterLabel;
  final VoidCallback onEdit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final date = _archiveDate(event.eventDate);
    final location = event.location.trim();
    final detail = [
      date,
      semesterLabel,
      if (location.isNotEmpty) location,
    ].where((value) => value.isNotEmpty).join(' · ');
    return ListTile(
      title: Text(event.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Wrap(
        children: [
          IconButton(
            tooltip: '编辑活动档案',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: '打开活动管理',
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
    );
  }
}

String _semesterLabel(EventModel event, Map<int, String> labels) {
  final id = event.semesterId;
  if (id == null) return '未归档学期';
  return labels[id] ?? '未知学期';
}

class _MemberArchiveDialog extends StatefulWidget {
  const _MemberArchiveDialog({
    required this.repository,
    required this.profile,
    required this.semesters,
    required this.onChanged,
    required this.onOpenEvents,
  });
  final LionRepository repository;
  final PersonProfile profile;
  final List<Semester> semesters;
  final VoidCallback onChanged;
  final VoidCallback onOpenEvents;

  @override
  State<_MemberArchiveDialog> createState() => _MemberArchiveDialogState();
}

class _MemberArchiveDialogState extends State<_MemberArchiveDialog> {
  late PersonProfile _profile;
  late List<Member> _history;
  late List<EventModel> _events;

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
    _reload();
  }

  void _reload() {
    _history = widget.repository
        .getMemberProfileHistory(_profile.id)
        .reversed
        .toList(growable: false);
    _events = widget.repository.getProfileEventHistory(_profile.id);
  }

  Future<void> _editProfile() async {
    final draft = await showDialog<_ProfileDraft>(
      context: context,
      builder: (context) => _ProfileEditor(profile: _profile),
    );
    if (draft == null || !mounted) return;
    try {
      widget.repository.updatePersonProfile(
        PersonProfile(
          id: _profile.id,
          displayName: draft.name,
          birthday: draft.birthday,
          createdAt: _profile.createdAt,
          updatedAt: _profile.updatedAt,
        ),
      );
      setState(() {
        _profile = widget.repository.getMemberProfile(_profile.id) ?? _profile;
      });
      widget.onChanged();
      _message('个人档案已更新');
    } catch (error) {
      _message('保存失败：$error');
    }
  }

  Future<void> _editMember(Member member) async {
    final updated = await showDialog<Member>(
      context: context,
      builder: (context) => _MemberEditor(member: member),
    );
    if (updated == null || !mounted) return;
    try {
      widget.repository.updateMember(updated);
      setState(_reload);
      widget.onChanged();
      _message('学期名册已更新');
    } catch (error) {
      _message('保存失败：$error');
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final labels = {for (final item in widget.semesters) item.id: item.label};
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 740,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          children: [
            ListTile(
              title: Text(
                _profile.displayName,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                _history.length.toString() +
                    ' 个学期 · ' +
                    _events.length.toString() +
                    ' 次活动',
              ),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: '编辑个人基本信息',
                    onPressed: _editProfile,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(_profile.displayName),
                    subtitle: Text(
                      '生日：' +
                          (_profile.birthday.isEmpty
                              ? '未填写'
                              : _profile.birthday),
                    ),
                  ),
                  const _SectionTitle('各学期名册'),
                  if (_history.isEmpty)
                    const ListTile(title: Text('尚无学期名册记录'))
                  else
                    ..._history.map(
                      (member) => _MemberHistoryTile(
                        member: member,
                        semesterLabel: labels[member.semesterId] ?? '未知学期',
                        onEdit: () => _editMember(member),
                      ),
                    ),
                  const _SectionTitle('参与活动'),
                  if (_events.isEmpty)
                    const ListTile(title: Text('暂无参与活动'))
                  else
                    ..._events.map((event) {
                      final date = _archiveDate(event.eventDate);
                      final semester = _semesterLabel(event, labels);
                      final location = event.location.trim();
                      final detail = [
                        date,
                        semester,
                        if (location.isNotEmpty) location,
                      ].where((value) => value.isNotEmpty).join(' · ');
                      return ListTile(
                        leading: const Icon(Icons.celebration_outlined),
                        title: Text(event.title),
                        subtitle: Text(detail),
                        trailing: IconButton(
                          tooltip: '打开活动管理',
                          onPressed: widget.onOpenEvents,
                          icon: const Icon(Icons.open_in_new_rounded),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberHistoryTile extends StatelessWidget {
  const _MemberHistoryTile({
    required this.member,
    required this.semesterLabel,
    required this.onEdit,
  });
  final Member member;
  final String semesterLabel;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final fields = [
      if (member.studentNo.isNotEmpty) '学号 ' + member.studentNo,
      if (member.grade.isNotEmpty) '年级 ' + member.grade,
      if (member.major.isNotEmpty) '专业 ' + member.major,
      if (member.position.isNotEmpty) '职位 ' + member.position,
      if (member.birthday.isNotEmpty) '生日 ' + member.birthday,
      if (member.contact?.trim().isNotEmpty == true)
        '联系方式 ' + member.contact!.trim(),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      child: ListTile(
        title: Text(semesterLabel),
        subtitle: Text(
          fields.isEmpty ? '暂无补充信息' : fields.join(' · '),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          tooltip: '编辑学期资料',
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
      ),
    );
  }
}
