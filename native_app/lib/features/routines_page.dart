import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/media_store.dart';
import 'document_viewer.dart';
import 'media_viewer.dart';

class RoutinesPage extends StatefulWidget {
  const RoutinesPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<RoutinesPage> createState() => _RoutinesPageState();
}

class _RoutinesPageState extends State<RoutinesPage> {
  late final MediaStore _mediaStore;
  final TextEditingController _searchController = TextEditingController();
  List<RoutineModel> _routines = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _mediaStore = MediaStore(
      supportDirectory: widget.repository.supportDirectory,
    );
    _loadRoutines();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadRoutines() {
    setState(() => _routines = widget.repository.getRoutines());
  }

  List<RoutineModel> get _visibleRoutines {
    if (_query.isEmpty) return _routines;
    final needle = _query.toLowerCase();
    return _routines
        .where((routine) {
          return routine.title.toLowerCase().contains(needle) ||
              routine.music.toLowerCase().contains(needle) ||
              routine.movements.toLowerCase().contains(needle) ||
              routine.notes.toLowerCase().contains(needle);
        })
        .toList(growable: false);
  }

  Future<void> _editRoutine([RoutineModel? routine]) async {
    final draft = await showDialog<_RoutineDraft>(
      context: context,
      builder: (context) => _RoutineEditorDialog(routine: routine),
    );
    if (draft == null || !mounted) return;
    try {
      final music = _joinMusic(draft.musicName, draft.musicVersion);
      int? createdId;
      if (routine == null) {
        createdId = widget.repository.addRoutine(
          title: draft.title,
          music: music,
          movements: draft.movements,
          notes: draft.notes,
        );
      } else {
        widget.repository.updateRoutine(
          RoutineModel(
            id: routine.id,
            title: draft.title,
            music: music,
            movements: draft.movements,
            notes: draft.notes,
            createdAt: routine.createdAt,
            updatedAt: routine.updatedAt,
          ),
        );
      }
      _loadRoutines();
      _showMessage(routine == null ? '套路已添加' : '套路资料已更新');
      if (routine == null) {
        final created = widget.repository.getRoutine(createdId!);
        if (created != null && mounted) _showDetails(created);
      }
    } catch (error) {
      _showMessage('保存失败：$error');
    }
  }

  Future<void> _deleteRoutine(RoutineModel routine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除套路？'),
        content: Text('确定删除“${routine.title}”吗？关联的附件也会从本机资料库中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除套路'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      for (final asset in widget.repository.getMediaAssets(
        ownerType: 'routine',
        ownerId: routine.id,
      )) {
        await widget.repository.deleteMediaAsset(asset.id);
        await _mediaStore.removeAsset(asset.mediaKey);
      }
      widget.repository.deleteRoutine(routine.id);
      _loadRoutines();
      _showMessage('套路已删除');
    } catch (error) {
      _showMessage('删除失败：$error');
    }
  }

  Future<void> _showDetails(RoutineModel routine) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _RoutineDetailsDialog(
        repository: widget.repository,
        mediaStore: _mediaStore,
        routine: routine,
      ),
    );
    if (mounted) _loadRoutines();
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
    final routines = _visibleRoutines;

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
                              '套路编排',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '记录配乐版本、动作队形、排练要点和参考素材。',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: () => _editRoutine(),
                        icon: const Icon(Icons.add),
                        label: const Text('添加套路'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '搜索套路、配乐或排练记录',
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
                  if (routines.isEmpty)
                    _RoutinesEmptyState(hasQuery: _query.isNotEmpty)
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: routines.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: 248,
                      ),
                      itemBuilder: (context, index) => _RoutineCard(
                        routine: routines[index],
                        attachmentCount: widget.repository
                            .getMediaAssets(
                              ownerType: 'routine',
                              ownerId: routines[index].id,
                            )
                            .length,
                        onOpen: () => _showDetails(routines[index]),
                        onEdit: () => _editRoutine(routines[index]),
                        onDelete: () => _deleteRoutine(routines[index]),
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

class _RoutineCard extends StatelessWidget {
  const _RoutineCard({
    required this.routine,
    required this.attachmentCount,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final RoutineModel routine;
  final int attachmentCount;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final music = _splitMusic(routine.music);
    final musicLine = [
      music.name,
      if (music.version.isNotEmpty) music.version,
    ].where((value) => value.isNotEmpty).join(' · ');

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
                      color: colors.tertiaryContainer,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      Icons.theater_comedy_rounded,
                      color: colors.onTertiaryContainer,
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
                            routine.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            musicLine.isEmpty ? '尚未设置配乐' : musicLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '套路操作',
                    onSelected: (value) {
                      if (value == 'edit') onEdit();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑套路')),
                      PopupMenuItem(value: 'delete', child: Text('删除套路')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (routine.movements.isNotEmpty)
                Text(
                  routine.movements,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
                )
              else
                Text(
                  '还没有动作与队形记录。',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              const Spacer(),
              Divider(
                height: 20,
                color: colors.outlineVariant.withValues(alpha: 0.5),
              ),
              Row(
                children: [
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      routine.notes.isEmpty ? '暂无排练备注' : '含排练备注',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.attach_file_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$attachmentCount 个附件',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
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

class _RoutinesEmptyState extends StatelessWidget {
  const _RoutinesEmptyState({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 70, horizontal: 20),
        child: Column(
          children: [
            Icon(
              Icons.theater_comedy_outlined,
              size: 52,
              color: colors.primary,
            ),
            const SizedBox(height: 12),
            Text(
              hasQuery ? '没有匹配的套路' : '还没有套路资料',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery ? '换个关键词试试。' : '添加配乐、动作队形和排练备注，整理每套表演内容。',
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

class _RoutineEditorDialog extends StatefulWidget {
  const _RoutineEditorDialog({required this.routine});

  final RoutineModel? routine;

  @override
  State<_RoutineEditorDialog> createState() => _RoutineEditorDialogState();
}

class _RoutineEditorDialogState extends State<_RoutineEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _musicName;
  late final TextEditingController _musicVersion;
  late final TextEditingController _movements;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final routine = widget.routine;
    final music = _splitMusic(routine?.music ?? '');
    _title = TextEditingController(text: routine?.title ?? '');
    _musicName = TextEditingController(text: music.name);
    _musicVersion = TextEditingController(text: music.version);
    _movements = TextEditingController(text: routine?.movements ?? '');
    _notes = TextEditingController(text: routine?.notes ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _musicName.dispose();
    _musicVersion.dispose();
    _movements.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _RoutineDraft(
        title: _title.text.trim(),
        musicName: _musicName.text.trim(),
        musicVersion: _musicVersion.text.trim(),
        movements: _movements.text.trim(),
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.routine == null ? '添加套路' : '编辑套路'),
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
                    labelText: '套路名称 *',
                    prefixIcon: Icon(Icons.theater_comedy_outlined),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入套路名称' : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _musicName,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '配乐名称',
                          prefixIcon: Icon(Icons.music_note_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _musicVersion,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '版本 / 节奏',
                          prefixIcon: Icon(Icons.graphic_eq_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _movements,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '动作与队形记录',
                    hintText: '例如：开场动作、队形变化、衔接和收尾要点',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.schema_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '排练备注',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.sticky_note_2_outlined),
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
        FilledButton(onPressed: _save, child: const Text('保存套路')),
      ],
    );
  }
}

class _RoutineDraft {
  const _RoutineDraft({
    required this.title,
    required this.musicName,
    required this.musicVersion,
    required this.movements,
    required this.notes,
  });

  final String title;
  final String musicName;
  final String musicVersion;
  final String movements;
  final String notes;
}

class _RoutineDetailsDialog extends StatefulWidget {
  const _RoutineDetailsDialog({
    required this.repository,
    required this.mediaStore,
    required this.routine,
  });

  final LionRepository repository;
  final MediaStore mediaStore;
  final RoutineModel routine;

  @override
  State<_RoutineDetailsDialog> createState() => _RoutineDetailsDialogState();
}

class _RoutineDetailsDialogState extends State<_RoutineDetailsDialog> {
  late List<MediaAssetModel> _assets;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _assets = widget.repository.getMediaAssets(
      ownerType: 'routine',
      ownerId: widget.routine.id,
    );
  }

  Future<void> _addAttachment() async {
    setState(() => _busy = true);
    try {
      final ref = await widget.mediaStore.pickMedia(
        dialogTitle: '选择套路照片、视频或音频',
      );
      if (ref == null || !mounted) return;
      try {
        widget.repository.putMediaAssetMetadata(
          mediaKey: ref.mediaKey,
          relativePath: ref.relativePath,
          ownerType: 'routine',
          ownerId: widget.routine.id,
          role: _routineMediaRole(ref.mimeType),
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

  Future<void> _addDocumentAttachment() async {
    setState(() => _busy = true);
    try {
      final ref = await widget.mediaStore.importDocumentFile(
        dialogTitle: '选择 PDF 或 DOCX 文件',
      );
      if (ref == null || !mounted) return;
      final isDocx =
          ref.fileName.toLowerCase().endsWith('.docx') ||
          ref.mimeType ==
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      if (isDocx && ref.fileSize > 16 * 1024 * 1024) {
        await widget.mediaStore.removeAsset(ref.mediaKey);
        throw const FormatException('DOCX 文件超过 16 MB，无法在应用内预览。');
      }
      try {
        widget.repository.putMediaAssetMetadata(
          mediaKey: ref.mediaKey,
          relativePath: ref.relativePath,
          ownerType: 'routine',
          ownerId: widget.routine.id,
          role: 'document',
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
      _message('添加文档附件失败：$error');
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
    if (_isRoutineDocumentPreviewable(asset)) {
      final file = await widget.mediaStore.resolveFile(asset.mediaKey);
      if (!mounted) return;
      if (file == null) {
        _message('本机找不到这个文档附件。');
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
    final music = _splitMusic(widget.routine.music);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 800),
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
                          widget.routine.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            music.name,
                            if (music.version.isNotEmpty) music.version,
                          ].where((value) => value.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                  _RoutineTextSection(
                    icon: Icons.schema_outlined,
                    title: '动作要点与队形编排',
                    content: widget.routine.movements,
                    emptyMessage: '还没有动作或队形记录。',
                  ),
                  const SizedBox(height: 18),
                  _RoutineTextSection(
                    icon: Icons.sticky_note_2_outlined,
                    title: '排练备注',
                    content: widget.routine.notes,
                    emptyMessage: '还没有排练备注。',
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '参考附件（${_assets.length}）',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
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
                        label: const Text('添加素材'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _addDocumentAttachment,
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('添加 PDF/DOCX'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '照片、视频、音频和 PDF/DOCX 文档均保存在本机资料库；点击附件可在应用内查看。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  for (final category in _routineAttachmentCategories)
                    _RoutineAttachmentCategory(
                      category: category,
                      assets: _assets
                          .where(
                            (asset) =>
                                _categoryForAsset(asset) == category.kind,
                          )
                          .toList(growable: false),
                      onOpen: _preview,
                      onRemove: _removeAttachment,
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

class _RoutineTextSection extends StatelessWidget {
  const _RoutineTextSection({
    required this.icon,
    required this.title,
    required this.content,
    required this.emptyMessage,
  });

  final IconData icon;
  final String title;
  final String content;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          content.isEmpty ? emptyMessage : content,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: content.isEmpty ? colors.onSurfaceVariant : colors.onSurface,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _RoutineAttachmentCategory extends StatelessWidget {
  const _RoutineAttachmentCategory({
    required this.category,
    required this.assets,
    required this.onOpen,
    required this.onRemove,
  });

  final _RoutineAttachmentCategoryInfo category;
  final List<MediaAssetModel> assets;
  final ValueChanged<MediaAssetModel> onOpen;
  final ValueChanged<MediaAssetModel> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(category.icon, size: 17, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                '${category.label} (${assets.length})',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (assets.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                '暂无${category.label}附件。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            )
          else
            ...assets.map(
              (asset) => _RoutineAttachmentTile(
                asset: asset,
                onOpen: () => onOpen(asset),
                onRemove: () => onRemove(asset),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoutineAttachmentTile extends StatelessWidget {
  const _RoutineAttachmentTile({
    required this.asset,
    required this.onOpen,
    required this.onRemove,
  });

  final MediaAssetModel asset;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final category = _categoryForAsset(asset);
    final icon = switch (category) {
      _RoutineAttachmentKind.photo => Icons.image_outlined,
      _RoutineAttachmentKind.video => Icons.movie_outlined,
      _RoutineAttachmentKind.audio => Icons.audiotrack_outlined,
      _RoutineAttachmentKind.word => Icons.article_outlined,
      _RoutineAttachmentKind.pdf => Icons.picture_as_pdf_outlined,
    };
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: const EdgeInsets.only(top: 8),
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: colors.secondaryContainer,
          child: Icon(icon, color: colors.onSecondaryContainer),
        ),
        title: Text(
          asset.title.isEmpty ? asset.fileName : asset.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${asset.fileName} · ${_formatRoutineBytes(asset.fileSize)}',
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

enum _RoutineAttachmentKind { photo, video, audio, word, pdf }

class _RoutineAttachmentCategoryInfo {
  const _RoutineAttachmentCategoryInfo({
    required this.kind,
    required this.label,
    required this.icon,
  });

  final _RoutineAttachmentKind kind;
  final String label;
  final IconData icon;
}

const _routineAttachmentCategories = <_RoutineAttachmentCategoryInfo>[
  _RoutineAttachmentCategoryInfo(
    kind: _RoutineAttachmentKind.photo,
    label: '照片',
    icon: Icons.image_outlined,
  ),
  _RoutineAttachmentCategoryInfo(
    kind: _RoutineAttachmentKind.video,
    label: '视频',
    icon: Icons.movie_outlined,
  ),
  _RoutineAttachmentCategoryInfo(
    kind: _RoutineAttachmentKind.audio,
    label: '音频',
    icon: Icons.audiotrack_outlined,
  ),
  _RoutineAttachmentCategoryInfo(
    kind: _RoutineAttachmentKind.word,
    label: 'Word 文档',
    icon: Icons.article_outlined,
  ),
  _RoutineAttachmentCategoryInfo(
    kind: _RoutineAttachmentKind.pdf,
    label: 'PDF 文件',
    icon: Icons.picture_as_pdf_outlined,
  ),
];

_RoutineAttachmentKind _categoryForAsset(MediaAssetModel asset) {
  if (asset.mimeType.startsWith('image/')) return _RoutineAttachmentKind.photo;
  if (asset.mimeType.startsWith('video/')) return _RoutineAttachmentKind.video;
  if (asset.mimeType.startsWith('audio/')) return _RoutineAttachmentKind.audio;
  if (asset.mimeType == 'application/pdf' ||
      asset.fileName.toLowerCase().endsWith('.pdf')) {
    return _RoutineAttachmentKind.pdf;
  }
  if (asset.fileName.toLowerCase().endsWith('.doc') ||
      asset.fileName.toLowerCase().endsWith('.docx') ||
      asset.mimeType == 'application/msword' ||
      asset.mimeType ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
    return _RoutineAttachmentKind.word;
  }
  return _RoutineAttachmentKind.photo;
}

bool _isRoutineDocumentPreviewable(MediaAssetModel asset) {
  final fileName = asset.fileName.toLowerCase();
  return asset.mimeType == 'application/pdf' ||
      fileName.endsWith('.pdf') ||
      fileName.endsWith('.docx') ||
      asset.mimeType ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
}

String _routineMediaRole(String mimeType) =>
    switch (mimeType.split('/').first) {
      'image' => 'photo',
      'video' => 'video',
      'audio' => 'audio',
      _ => 'attachment',
    };

({String name, String version}) _splitMusic(String music) {
  const versionLabel = '\n版本：';
  final marker = music.indexOf(versionLabel);
  if (marker >= 0) {
    return (
      name: music.substring(0, marker),
      version: music.substring(marker + versionLabel.length),
    );
  }
  final newline = music.indexOf('\n');
  if (newline >= 0) {
    return (
      name: music.substring(0, newline),
      version: music.substring(newline + 1),
    );
  }
  return (name: music, version: '');
}

String _joinMusic(String name, String version) => version.isEmpty
    ? name
    : name.isEmpty
    ? '版本：$version'
    : '$name\n版本：$version';

String _formatRoutineBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
