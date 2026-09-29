import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/media_store.dart';
import 'media_viewer.dart';

class EventsPage extends StatefulWidget {
  const EventsPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  late final MediaStore _mediaStore;
  final TextEditingController _searchController = TextEditingController();
  List<EventModel> _events = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _mediaStore = MediaStore(
      supportDirectory: widget.repository.supportDirectory,
    );
    _loadEvents();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadEvents() {
    setState(() => _events = widget.repository.getEvents());
  }

  List<EventModel> get _visibleEvents {
    if (_query.isEmpty) return _events;
    final needle = _query.toLowerCase();
    return _events
        .where((event) {
          return event.title.toLowerCase().contains(needle) ||
              event.location.toLowerCase().contains(needle) ||
              event.summary.toLowerCase().contains(needle);
        })
        .toList(growable: false);
  }

  Future<void> _editEvent([EventModel? event]) async {
    final selectedMembers = event == null
        ? const <Member>[]
        : widget.repository.getEventParticipants(event.id);
    final currentSemester = widget.repository.getCurrentSemester();
    final roster = <int, Member>{};
    if (currentSemester != null) {
      for (final member in widget.repository.getMembers(
        currentSemester.id,
        activeOnly: true,
      )) {
        roster[member.id] = member;
      }
    }
    for (final member in selectedMembers) {
      roster[member.id] = member;
    }

    final draft = await showDialog<_EventDraft>(
      context: context,
      builder: (context) => _EventEditorDialog(
        event: event,
        members: roster.values.toList(growable: false),
        selectedMemberIds: selectedMembers.map((member) => member.id).toSet(),
      ),
    );
    if (draft == null || !mounted) return;

    try {
      final id = event == null
          ? widget.repository.addEvent(
              title: draft.title,
              eventDate: draft.eventDate,
              location: draft.location,
              summary: draft.summary,
            )
          : event.id;
      if (event != null) {
        widget.repository.updateEvent(
          EventModel(
            id: event.id,
            title: draft.title,
            eventDate: draft.eventDate,
            location: draft.location,
            summary: draft.summary,
            createdAt: event.createdAt,
            updatedAt: event.updatedAt,
          ),
        );
      }
      widget.repository.replaceEventParticipants(id, draft.memberIds);
      _loadEvents();
      _showMessage(event == null ? '活动已添加' : '活动信息已更新');
      if (event == null) {
        final created = widget.repository.getEvent(id);
        if (created != null && mounted) _showDetails(created);
      }
    } catch (error) {
      _showMessage('保存失败：$error');
    }
  }

  Future<void> _deleteEvent(EventModel event) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除活动？'),
        content: Text('确定删除“${event.title}”吗？活动资料和附件关联也会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除活动'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      for (final asset in widget.repository.getMediaAssets(
        ownerType: 'event',
        ownerId: event.id,
      )) {
        await widget.repository.deleteMediaAsset(asset.id);
        await _mediaStore.removeAsset(asset.mediaKey);
      }
      widget.repository.deleteEvent(event.id);
      _loadEvents();
      _showMessage('活动已删除');
    } catch (error) {
      _showMessage('删除失败：$error');
    }
  }

  Future<void> _showDetails(EventModel event) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _EventDetailsDialog(
        repository: widget.repository,
        mediaStore: _mediaStore,
        event: event,
      ),
    );
    if (mounted) _loadEvents();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1280
        ? 3
        : width >= 800
        ? 2
        : 1;
    final events = _visibleEvents;

    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 560 ? 18.0 : 32.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            28,
            horizontalPadding,
            40,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '活动记录',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '整理活动日期、地点、参与成员和现场影像。',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: () => _editEvent(),
                        icon: const Icon(Icons.add),
                        label: const Text('添加活动'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '搜索活动名称、地点或摘要',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                onPressed: _searchController.clear,
                                tooltip: '清除搜索',
                                icon: const Icon(Icons.close),
                              ),
                        filled: true,
                        fillColor: colors.surfaceContainerLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  if (events.isEmpty)
                    _EventsEmptyState(hasQuery: _query.isNotEmpty)
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: events.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: 248,
                      ),
                      itemBuilder: (context, index) => _EventCard(
                        event: events[index],
                        participantCount: widget.repository
                            .getEventParticipants(events[index].id)
                            .length,
                        attachmentCount: widget.repository
                            .getMediaAssets(
                              ownerType: 'event',
                              ownerId: events[index].id,
                            )
                            .length,
                        onOpen: () => _showDetails(events[index]),
                        onEdit: () => _editEvent(events[index]),
                        onDelete: () => _deleteEvent(events[index]),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.participantCount,
    required this.attachmentCount,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final EventModel event;
  final int participantCount;
  final int attachmentCount;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final parsedDate = DateTime.tryParse(event.eventDate);
    final dateLabel = parsedDate == null
        ? (event.eventDate.isEmpty ? '日期未设置' : event.eventDate)
        : '${parsedDate.year}年${parsedDate.month}月${parsedDate.day}日';

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      Icons.event_rounded,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            dateLabel,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: colors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '活动操作',
                    onSelected: (value) {
                      if (value == 'edit') onEdit();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑活动')),
                      PopupMenuItem(value: 'delete', child: Text('删除活动')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (event.location.isNotEmpty)
                _EventMetaLine(
                  icon: Icons.place_outlined,
                  text: event.location,
                ),
              if (event.summary.isNotEmpty) ...[
                if (event.location.isNotEmpty) const SizedBox(height: 9),
                Text(
                  event.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
                ),
              ],
              const Spacer(),
              Divider(
                height: 20,
                color: colors.outlineVariant.withValues(alpha: 0.5),
              ),
              Row(
                children: [
                  Expanded(
                    child: _EventMetaLine(
                      icon: Icons.people_alt_outlined,
                      text: '$participantCount 位成员',
                    ),
                  ),
                  const Spacer(),
                  Expanded(
                    child: _EventMetaLine(
                      icon: Icons.attach_file_rounded,
                      text: '$attachmentCount 个附件',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventMetaLine extends StatelessWidget {
  const _EventMetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _EventsEmptyState extends StatelessWidget {
  const _EventsEmptyState({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 70, horizontal: 20),
        child: Column(
          children: [
            Icon(Icons.event_note_outlined, size: 52, color: colors.primary),
            const SizedBox(height: 12),
            Text(
              hasQuery ? '没有匹配的活动' : '还没有活动记录',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery ? '换个关键词试试。' : '添加活动后，可以在这里整理参与成员和现场资料。',
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

class _EventEditorDialog extends StatefulWidget {
  const _EventEditorDialog({
    required this.event,
    required this.members,
    required this.selectedMemberIds,
  });

  final EventModel? event;
  final List<Member> members;
  final Set<int> selectedMemberIds;

  @override
  State<_EventEditorDialog> createState() => _EventEditorDialogState();
}

class _EventEditorDialogState extends State<_EventEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _date;
  late final TextEditingController _location;
  late final TextEditingController _summary;
  late final Set<int> _selectedMemberIds;

  @override
  void initState() {
    super.initState();
    final event = widget.event;
    _title = TextEditingController(text: event?.title ?? '');
    _date = TextEditingController(
      text: event?.eventDate.isNotEmpty == true
          ? event!.eventDate
          : _formatDate(DateTime.now()),
    );
    _location = TextEditingController(text: event?.location ?? '');
    _summary = TextEditingController(text: event?.summary ?? '');
    _selectedMemberIds = Set<int>.from(widget.selectedMemberIds);
  }

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    _location.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(_date.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      helpText: '选择活动日期',
    );
    if (picked != null) _date.text = _formatDate(picked);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _EventDraft(
        title: _title.text.trim(),
        eventDate: _date.text.trim(),
        location: _location.text.trim(),
        summary: _summary.text.trim(),
        memberIds: _selectedMemberIds,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.event == null ? '添加活动' : '编辑活动'),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _title,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '活动名称 *',
                    prefixIcon: Icon(Icons.event_outlined),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入活动名称' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _date,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: '活动日期 *',
                    prefixIcon: const Icon(Icons.calendar_month_outlined),
                    suffixIcon: IconButton(
                      onPressed: _pickDate,
                      tooltip: '选择日期',
                      icon: const Icon(Icons.calendar_today_outlined),
                    ),
                  ),
                  onTap: _pickDate,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _location,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '地点',
                    prefixIcon: Icon(Icons.place_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _summary,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '活动摘要',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.notes_outlined),
                  ),
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '参与成员',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        '${_selectedMemberIds.length} 位已选',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                if (widget.members.isEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '当前学期还没有在册成员。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  Container(
                    constraints: const BoxConstraints(maxHeight: 210),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: widget.members.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final member = widget.members[index];
                        return CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(member.name),
                          subtitle: member.studentNo.isEmpty
                              ? null
                              : Text(member.studentNo),
                          value: _selectedMemberIds.contains(member.id),
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              _selectedMemberIds.add(member.id);
                            } else {
                              _selectedMemberIds.remove(member.id);
                            }
                          }),
                        );
                      },
                    ),
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
        FilledButton(onPressed: _save, child: const Text('保存活动')),
      ],
    );
  }
}

class _EventDraft {
  const _EventDraft({
    required this.title,
    required this.eventDate,
    required this.location,
    required this.summary,
    required this.memberIds,
  });

  final String title;
  final String eventDate;
  final String location;
  final String summary;
  final Set<int> memberIds;
}

class _EventDetailsDialog extends StatefulWidget {
  const _EventDetailsDialog({
    required this.repository,
    required this.mediaStore,
    required this.event,
  });

  final LionRepository repository;
  final MediaStore mediaStore;
  final EventModel event;

  @override
  State<_EventDetailsDialog> createState() => _EventDetailsDialogState();
}

class _EventDetailsDialogState extends State<_EventDetailsDialog> {
  late List<MediaAssetModel> _assets;
  late List<Member> _participants;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _assets = widget.repository.getMediaAssets(
      ownerType: 'event',
      ownerId: widget.event.id,
    );
    _participants = widget.repository.getEventParticipants(widget.event.id);
  }

  Future<void> _addAttachment() async {
    setState(() => _busy = true);
    try {
      final ref = await widget.mediaStore.pickMedia(
        dialogTitle: '选择活动照片、视频或音频',
      );
      if (ref == null || !mounted) return;
      try {
        widget.repository.putMediaAssetMetadata(
          mediaKey: ref.mediaKey,
          relativePath: ref.relativePath,
          ownerType: 'event',
          ownerId: widget.event.id,
          role: _mediaRole(ref.mimeType),
          title: ref.title,
          fileName: ref.fileName,
          mimeType: ref.mimeType,
          fileSize: ref.fileSize,
        );
      } catch (_) {
        await widget.mediaStore.removeAsset(ref.mediaKey);
        rethrow;
      }
      setState(_reload);
    } catch (error) {
      _message('添加附件失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAttachment(MediaAssetModel asset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除附件？'),
        content: Text('“${asset.fileName}”将从本机资料库中删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deleteMediaAsset(asset.id);
      await widget.mediaStore.removeAsset(asset.mediaKey);
      setState(_reload);
    } catch (error) {
      _message('移除附件失败：$error');
    }
  }

  Future<void> _preview(MediaAssetModel asset) async {
    await showMediaViewer(
      context: context,
      mediaStore: widget.mediaStore,
      asset: asset,
    );
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final parsedDate = DateTime.tryParse(widget.event.eventDate);
    final dateLabel = parsedDate == null
        ? widget.event.eventDate
        : '${parsedDate.year}年${parsedDate.month}月${parsedDate.day}日';

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 780),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.event.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            dateLabel,
                            if (widget.event.location.isNotEmpty)
                              widget.event.location,
                          ].where((value) => value.isNotEmpty).join(' · '),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                children: [
                  if (widget.event.summary.isNotEmpty) ...[
                    Text(
                      '活动摘要',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      widget.event.summary,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(height: 1.5),
                    ),
                    const SizedBox(height: 22),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '参与成员（${_participants.length}）',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_participants.isEmpty)
                    Text(
                      '尚未选择参与成员。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _participants
                          .map(
                            (member) => Chip(
                              avatar: CircleAvatar(
                                radius: 11,
                                backgroundColor: colors.primaryContainer,
                                child: Text(
                                  member.name.isEmpty
                                      ? '·'
                                      : String.fromCharCode(
                                          member.name.runes.first,
                                        ),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.onPrimaryContainer,
                                  ),
                                ),
                              ),
                              label: Text(member.name),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '活动附件（${_assets.length}）',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _addAttachment,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.attach_file),
                        label: const Text('添加附件'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_assets.isEmpty)
                    Text(
                      '可以添加照片、视频或音频。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    )
                  else
                    ..._assets.map(
                      (asset) => _AttachmentTile(
                        asset: asset,
                        onOpen: () => _preview(asset),
                        onRemove: () => _removeAttachment(asset),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.asset,
    required this.onOpen,
    required this.onRemove,
  });

  final MediaAssetModel asset;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final kind = _mediaKind(asset.mimeType);
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: colors.secondaryContainer,
          child: Icon(_iconForMedia(kind), color: colors.onSecondaryContainer),
        ),
        title: Text(
          asset.title.isEmpty ? asset.fileName : asset.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${_mediaKindLabel(kind)} · ${_formatBytes(asset.fileSize)}',
        ),
        trailing: IconButton(
          onPressed: onRemove,
          tooltip: '移除附件',
          icon: const Icon(Icons.delete_outline),
        ),
      ),
    );
  }
}

enum _MediaKind { image, video, audio, other }

_MediaKind _mediaKind(String mimeType) {
  if (mimeType.startsWith('image/')) return _MediaKind.image;
  if (mimeType.startsWith('video/')) return _MediaKind.video;
  if (mimeType.startsWith('audio/')) return _MediaKind.audio;
  return _MediaKind.other;
}

String _mediaRole(String mimeType) => switch (_mediaKind(mimeType)) {
  _MediaKind.image => 'photo',
  _MediaKind.video => 'video',
  _MediaKind.audio => 'audio',
  _MediaKind.other => 'attachment',
};

IconData _iconForMedia(_MediaKind kind) => switch (kind) {
  _MediaKind.image => Icons.image_outlined,
  _MediaKind.video => Icons.movie_outlined,
  _MediaKind.audio => Icons.audiotrack_outlined,
  _MediaKind.other => Icons.attach_file,
};

String _mediaKindLabel(_MediaKind kind) => switch (kind) {
  _MediaKind.image => '照片',
  _MediaKind.video => '视频',
  _MediaKind.audio => '音频',
  _MediaKind.other => '附件',
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
