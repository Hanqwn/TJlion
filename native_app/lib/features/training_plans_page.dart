import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/media_store.dart';
import 'document_viewer.dart';
import 'media_viewer.dart';

class TrainingPlansPage extends StatefulWidget {
  const TrainingPlansPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<TrainingPlansPage> createState() => _TrainingPlansPageState();
}

class _TrainingPlansPageState extends State<TrainingPlansPage> {
  late final MediaStore _mediaStore;
  final TextEditingController _searchController = TextEditingController();
  List<Semester> _semesters = const [];
  List<TrainingPlanModel> _plans = const [];
  List<LegacyAssetModel> _legacyAssets = const [];
  int? _semesterId;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _mediaStore = MediaStore(
      supportDirectory: widget.repository.supportDirectory,
    );
    _legacyAssets = widget.repository.getLegacyAssets();
    _loadSemesters();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadSemesters({int? preferredSemesterId}) {
    final semesters = widget.repository.getSemesters();
    final preferred = preferredSemesterId ?? _semesterId;
    final selected = semesters.any((item) => item.id == preferred)
        ? preferred
        : widget.repository.getCurrentSemester()?.id ??
              (semesters.isEmpty ? null : semesters.first.id);
    setState(() {
      _semesters = semesters;
      _semesterId = selected;
      _plans = selected == null
          ? const []
          : widget.repository.getTrainingPlans(selected);
    });
  }

  List<TrainingPlanModel> get _visiblePlans {
    if (_query.isEmpty) return _plans;
    final needle = _query.toLowerCase();
    return _plans
        .where((plan) {
          return plan.title.toLowerCase().contains(needle) ||
              plan.content.toLowerCase().contains(needle);
        })
        .toList(growable: false);
  }

  LegacyAssetModel? _legacyAsset(int? id) {
    if (id == null) return null;
    for (final asset in _legacyAssets) {
      if (asset.id == id) return asset;
    }
    return widget.repository.getLegacyAsset(id);
  }

  Future<void> _editPlan([TrainingPlanModel? plan]) async {
    final semesterId = _semesterId;
    if (semesterId == null) return;
    final draft = await showDialog<_PlanDraft>(
      context: context,
      builder: (context) => _PlanEditorDialog(
        plan: plan,
        legacyAssets: _legacyAssets,
        linkedAsset: _legacyAsset(plan?.legacyAssetId),
      ),
    );
    if (draft == null || !mounted) return;
    try {
      int? createdId;
      if (plan == null) {
        createdId = widget.repository.addTrainingPlan(
          semesterId: semesterId,
          title: draft.title,
          content: draft.content,
          legacyAssetId: draft.legacyAssetId,
        );
      } else {
        widget.repository.updateTrainingPlan(
          TrainingPlanModel(
            id: plan.id,
            semesterId: plan.semesterId,
            title: draft.title,
            content: draft.content,
            legacyAssetId: draft.legacyAssetId,
            createdAt: plan.createdAt,
            updatedAt: plan.updatedAt,
          ),
        );
      }
      _loadSemesters(preferredSemesterId: semesterId);
      _showMessage(plan == null ? '训练计划已添加' : '训练计划已更新');
      if (plan == null) {
        final created = widget.repository.getTrainingPlan(createdId!);
        if (created != null && mounted) _showDetails(created);
      }
    } catch (error) {
      _showMessage('保存失败：$error');
    }
  }

  Future<void> _deletePlan(TrainingPlanModel plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除训练计划？'),
        content: Text('确定删除“${plan.title}”吗？已选资料库附件本身会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除计划'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      for (final asset in widget.repository.getMediaAssets(
        ownerType: 'plan',
        ownerId: plan.id,
      )) {
        await widget.repository.deleteMediaAsset(asset.id);
        await _mediaStore.removeAsset(asset.mediaKey);
      }
      widget.repository.deleteTrainingPlan(plan.id);
      _loadSemesters(preferredSemesterId: _semesterId);
      _showMessage('训练计划已删除');
    } catch (error) {
      _showMessage('删除失败：$error');
    }
  }

  Future<void> _showDetails(TrainingPlanModel plan) async {
    final semester = _semesters
        .where((item) => item.id == plan.semesterId)
        .firstOrNull;
    await showDialog<void>(
      context: context,
      builder: (context) => _PlanDetailsDialog(
        repository: widget.repository,
        mediaStore: _mediaStore,
        plan: plan,
        semesterLabel: semester?.label ?? '学期资料',
        linkedAsset: _legacyAsset(plan.legacyAssetId),
      ),
    );
    if (mounted) _loadSemesters(preferredSemesterId: _semesterId);
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
    final plans = _visiblePlans;
    final selectedSemester = _semesters
        .where((item) => item.id == _semesterId)
        .firstOrNull;

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
                              '训练计划',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '按学期整理训练主题、阶段安排和参考资料。',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _semesterId == null
                            ? null
                            : () => _editPlan(),
                        icon: const Icon(Icons.add),
                        label: const Text('添加计划'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Wrap(
                    spacing: 14,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: constraints.maxWidth < 540
                            ? constraints.maxWidth
                            : 260,
                        child: DropdownButtonFormField<int>(
                          initialValue: _semesterId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '学期',
                            prefixIcon: Icon(Icons.school_outlined),
                            border: OutlineInputBorder(),
                          ),
                          items: _semesters
                              .map(
                                (semester) => DropdownMenuItem<int>(
                                  value: semester.id,
                                  child: Text(
                                    '${semester.label}${semester.isCurrent ? ' · 当前' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value != null) {
                              _loadSemesters(preferredSemesterId: value);
                            }
                          },
                        ),
                      ),
                      SizedBox(
                        width: constraints.maxWidth < 540
                            ? constraints.maxWidth
                            : 460,
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: '搜索计划或内容',
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
                    ],
                  ),
                  const SizedBox(height: 22),
                  if (selectedSemester == null)
                    const _PlansEmptyState(
                      title: '尚未设置学期',
                      message: '先在成员资料中建立学期，再添加训练计划。',
                    )
                  else if (plans.isEmpty)
                    _PlansEmptyState(
                      title: _query.isEmpty ? '这个学期还没有计划' : '没有匹配的计划',
                      message: _query.isEmpty
                          ? '为 ${selectedSemester.label} 添加训练安排。'
                          : '换个关键词试试。',
                    )
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: plans.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: 254,
                      ),
                      itemBuilder: (context, index) {
                        final plan = plans[index];
                        return _PlanCard(
                          plan: plan,
                          semesterLabel: selectedSemester.label,
                          linkedAsset: _legacyAsset(plan.legacyAssetId),
                          mediaCount: widget.repository
                              .getMediaAssets(
                                ownerType: 'plan',
                                ownerId: plan.id,
                              )
                              .length,
                          onOpen: () => _showDetails(plan),
                          onEdit: () => _editPlan(plan),
                          onDelete: () => _deletePlan(plan),
                        );
                      },
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

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.semesterLabel,
    required this.linkedAsset,
    required this.mediaCount,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final TrainingPlanModel plan;
  final String semesterLabel;
  final LegacyAssetModel? linkedAsset;
  final int mediaCount;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
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
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      Icons.calendar_month_outlined,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          plan.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          semesterLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.primary),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '计划操作',
                    onSelected: (value) {
                      if (value == 'edit') onEdit();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑计划')),
                      PopupMenuItem(value: 'delete', child: Text('删除计划')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Text(
                  plan.content.isEmpty ? '还没有填写计划内容。' : plan.content,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
                ),
              ),
              Divider(
                height: 18,
                color: colors.outlineVariant.withValues(alpha: 0.5),
              ),
              Row(
                children: [
                  Icon(
                    linkedAsset == null
                        ? Icons.attach_file_rounded
                        : _legacyAssetIcon(linkedAsset!),
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      linkedAsset?.title ?? '未关联资料库文件',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$mediaCount 个附件',
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

class _PlansEmptyState extends StatelessWidget {
  const _PlansEmptyState({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 70, horizontal: 20),
        child: Column(
          children: [
            Icon(
              Icons.calendar_month_outlined,
              size: 52,
              color: colors.primary,
            ),
            const SizedBox(height: 12),
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

class _PlanEditorDialog extends StatefulWidget {
  const _PlanEditorDialog({
    required this.plan,
    required this.legacyAssets,
    required this.linkedAsset,
  });

  final TrainingPlanModel? plan;
  final List<LegacyAssetModel> legacyAssets;
  final LegacyAssetModel? linkedAsset;

  @override
  State<_PlanEditorDialog> createState() => _PlanEditorDialogState();
}

class _PlanEditorDialogState extends State<_PlanEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _content;
  int? _legacyAssetId;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.plan?.title ?? '');
    _content = TextEditingController(text: widget.plan?.content ?? '');
    _legacyAssetId = widget.plan?.legacyAssetId;
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _chooseAsset() async {
    final selectedId = await showDialog<int>(
      context: context,
      builder: (context) => _LegacyAssetPickerDialog(
        assets: widget.legacyAssets,
        selectedAssetId: _legacyAssetId,
      ),
    );
    if (selectedId == null) return;
    setState(() => _legacyAssetId = selectedId < 0 ? null : selectedId);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _PlanDraft(
        title: _title.text.trim(),
        content: _content.text.trim(),
        legacyAssetId: _legacyAssetId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected =
        widget.legacyAssets
            .where((item) => item.id == _legacyAssetId)
            .firstOrNull ??
        (widget.linkedAsset?.id == _legacyAssetId ? widget.linkedAsset : null);
    return AlertDialog(
      title: Text(widget.plan == null ? '添加训练计划' : '编辑训练计划'),
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
                    labelText: '计划名称 *',
                    prefixIcon: Icon(Icons.calendar_month_outlined),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入计划名称' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _content,
                  minLines: 4,
                  maxLines: 9,
                  decoration: const InputDecoration(
                    labelText: '训练安排与目标',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.notes_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '资料库附件',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _chooseAsset,
                  icon: Icon(
                    selected == null
                        ? Icons.attach_file
                        : _legacyAssetIcon(selected),
                  ),
                  label: Text(selected?.title ?? '从历史资料库选择文件'),
                ),
                if (selected != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_legacyFileName(selected)} · ${_legacyAssetKind(selected)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '照片、视频和音频可在计划详情中添加。PDF 可预览；DOCX 显示提取文字，旧版 DOC 仅显示信息。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        FilledButton(onPressed: _save, child: const Text('保存计划')),
      ],
    );
  }
}

class _PlanDraft {
  const _PlanDraft({
    required this.title,
    required this.content,
    required this.legacyAssetId,
  });

  final String title;
  final String content;
  final int? legacyAssetId;
}

class _PlanDetailsDialog extends StatefulWidget {
  const _PlanDetailsDialog({
    required this.repository,
    required this.mediaStore,
    required this.plan,
    required this.semesterLabel,
    required this.linkedAsset,
  });

  final LionRepository repository;
  final MediaStore mediaStore;
  final TrainingPlanModel plan;
  final String semesterLabel;
  final LegacyAssetModel? linkedAsset;

  @override
  State<_PlanDetailsDialog> createState() => _PlanDetailsDialogState();
}

class _PlanDetailsDialogState extends State<_PlanDetailsDialog> {
  late List<MediaAssetModel> _assets;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _assets = widget.repository.getMediaAssets(
      ownerType: 'plan',
      ownerId: widget.plan.id,
    );
  }

  Future<void> _addAttachment() async {
    setState(() => _busy = true);
    try {
      final ref = await widget.mediaStore.pickMedia(
        dialogTitle: '选择训练计划照片、视频或音频',
      );
      if (ref == null || !mounted) return;
      try {
        widget.repository.putMediaAssetMetadata(
          mediaKey: ref.mediaKey,
          relativePath: ref.relativePath,
          ownerType: 'plan',
          ownerId: widget.plan.id,
          role: _planMediaRole(ref.mimeType),
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
      if (_isWordDocument(ref.mimeType, ref.fileName.toLowerCase()) &&
          ref.fileSize > 16 * 1024 * 1024) {
        await widget.mediaStore.removeAsset(ref.mediaKey);
        throw const FormatException('DOCX 文件超过 16 MB，无法在应用内预览。');
      }
      try {
        widget.repository.putMediaAssetMetadata(
          mediaKey: ref.mediaKey,
          relativePath: ref.relativePath,
          ownerType: 'plan',
          ownerId: widget.plan.id,
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

  Future<void> _removeMedia(MediaAssetModel asset) async {
    final confirmed = await _confirmRemove(context, asset.fileName);
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deleteMediaAsset(asset.id);
      await widget.mediaStore.removeAsset(asset.mediaKey);
      setState(_reload);
    } catch (error) {
      _message('移除附件失败：$error');
    }
  }

  Future<void> _previewMedia(MediaAssetModel asset) async {
    final title = asset.title.isEmpty ? asset.fileName : asset.title;
    if (_isPdfAttachment(asset.mimeType, asset.fileName) ||
        _isWordDocument(asset.mimeType, asset.fileName.toLowerCase())) {
      final file = await widget.mediaStore.resolveFile(asset.mediaKey);
      if (!mounted) return;
      if (file == null) {
        await showDialog<void>(
          context: context,
          builder: (context) => _PlanFilePreviewDialog(
            title: title,
            fileName: asset.fileName,
            mimeType: asset.mimeType,
            fileSize: asset.fileSize,
            file: null,
          ),
        );
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
      mediaStore: widget.mediaStore,
      asset: asset,
    );
  }

  Future<void> _previewLegacy() async {
    final asset = widget.linkedAsset;
    if (asset == null) return;
    final file = await widget.repository.legacyAssetFile(asset.id);
    if (!mounted) return;
    final fileName = _legacyFileName(asset);
    if (file != null &&
        (_isPdfAttachment(asset.mimeType, fileName) ||
            _isWordDocument(asset.mimeType, fileName.toLowerCase()))) {
      await showDialog<void>(
        context: context,
        builder: (context) => DocumentViewer(
          file: file,
          title: asset.title,
          fileName: fileName,
          mimeType: asset.mimeType,
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _PlanFilePreviewDialog(
        title: asset.title,
        fileName: fileName,
        mimeType: asset.mimeType,
        fileSize: asset.fileSize,
        file: file,
        unsupportedMessage: _legacyPreviewMessage(asset),
      ),
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
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 790),
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
                          widget.plan.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.semesterLabel,
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
                  Text(
                    '训练安排',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    widget.plan.content.isEmpty
                        ? '暂无计划内容。'
                        : widget.plan.content,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.5,
                      color: widget.plan.content.isEmpty
                          ? colors.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '附件与参考资料',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
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
                            label: const Text('添加媒体'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _addDocumentAttachment,
                            icon: const Icon(Icons.description_outlined),
                            label: const Text('添加 PDF/DOCX'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '可添加照片、视频、音频，也可导入 PDF/DOCX。DOCX 以纯文本预览。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  if (widget.linkedAsset != null) ...[
                    const SizedBox(height: 12),
                    _PlanLinkedLegacyTile(
                      asset: widget.linkedAsset!,
                      onOpen: _previewLegacy,
                    ),
                  ],
                  if (_assets.isEmpty && widget.linkedAsset == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        '尚未添加附件。',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ..._assets.map(
                    (asset) => _PlanMediaTile(
                      asset: asset,
                      onOpen: () => _previewMedia(asset),
                      onRemove: () => _removeMedia(asset),
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

class _PlanLinkedLegacyTile extends StatelessWidget {
  const _PlanLinkedLegacyTile({required this.asset, required this.onOpen});

  final LegacyAssetModel asset;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: colors.secondaryContainer,
          child: Icon(
            _legacyAssetIcon(asset),
            color: colors.onSecondaryContainer,
          ),
        ),
        title: Text(asset.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_legacyFileName(asset)} · ${_legacyAssetKind(asset)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.open_in_new),
      ),
    );
  }
}

class _PlanMediaTile extends StatelessWidget {
  const _PlanMediaTile({
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
    final icon = _planAttachmentIcon(asset);
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
          '${asset.fileName} · ${_formatPlanBytes(asset.fileSize)}',
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

class _PlanFilePreviewDialog extends StatelessWidget {
  const _PlanFilePreviewDialog({
    required this.title,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.file,
    this.unsupportedMessage,
  });

  final String title;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final File? file;
  final String? unsupportedMessage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isImage = mimeType.startsWith('image/');
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('$fileName · ${_formatPlanBytes(fileSize)}'),
              trailing: IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '关闭预览',
                icon: const Icon(Icons.close),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: file == null
                    ? const Center(child: Text('本机找不到这个附件文件。'))
                    : isImage
                    ? InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 5,
                        child: Image.file(
                          file!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) =>
                              const Center(child: Text('无法显示这张图片。')),
                        ),
                      )
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 430),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  color: colors.primaryContainer,
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                child: Icon(
                                  _previewIcon(mimeType, fileName),
                                  size: 48,
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _previewType(mimeType, fileName),
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 7),
                              Text(fileName, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              Text(
                                unsupportedMessage ??
                                    _previewLimitation(mimeType, fileName),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegacyAssetPickerDialog extends StatefulWidget {
  const _LegacyAssetPickerDialog({
    required this.assets,
    required this.selectedAssetId,
  });

  final List<LegacyAssetModel> assets;
  final int? selectedAssetId;

  @override
  State<_LegacyAssetPickerDialog> createState() =>
      _LegacyAssetPickerDialogState();
}

class _LegacyAssetPickerDialogState extends State<_LegacyAssetPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _search.addListener(
      () => setState(() => _query = _search.text.trim().toLowerCase()),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.assets
        .where((asset) {
          if (_query.isEmpty) return true;
          return asset.title.toLowerCase().contains(_query) ||
              _legacyFileName(asset).toLowerCase().contains(_query) ||
              asset.category.toLowerCase().contains(_query) ||
              asset.groupName.toLowerCase().contains(_query);
        })
        .toList(growable: false);
    return AlertDialog(
      title: const Text('选择历史资料'),
      content: SizedBox(
        width: 560,
        height: 470,
        child: Column(
          children: [
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                hintText: '搜索标题、文件名或分类',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('没有可关联的历史资料文件。'))
                  : ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final asset = visible[index];
                        return ListTile(
                          leading: Icon(_legacyAssetIcon(asset)),
                          title: Text(
                            asset.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_legacyFileName(asset)} · ${_legacyAssetKind(asset)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: widget.selectedAssetId == asset.id
                              ? const Icon(Icons.check_circle)
                              : null,
                          onTap: () => Navigator.pop(context, asset.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, -1),
          child: const Text('移除已关联文件'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

Future<bool?> _confirmRemove(BuildContext context, String name) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除附件？'),
        content: Text('“$name”将从本机资料库中删除。'),
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

IconData _legacyAssetIcon(LegacyAssetModel asset) {
  final name = _legacyFileName(asset).toLowerCase();
  final mime = asset.mimeType.toLowerCase();
  if (mime.startsWith('image/') ||
      RegExp(r'\.(png|jpe?g|webp|gif|bmp)$').hasMatch(name)) {
    return Icons.image_outlined;
  }
  if (mime.startsWith('video/') ||
      RegExp(r'\.(mp4|mov|avi|mkv|webm)$').hasMatch(name)) {
    return Icons.movie_outlined;
  }
  if (mime.startsWith('audio/') ||
      RegExp(r'\.(mp3|wav|m4a|aac|ogg)$').hasMatch(name)) {
    return Icons.audiotrack_outlined;
  }
  if (mime == 'application/pdf' || name.endsWith('.pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  return Icons.article_outlined;
}

String _legacyAssetKind(LegacyAssetModel asset) {
  final icon = _legacyAssetIcon(asset);
  if (icon == Icons.image_outlined) return '照片';
  if (icon == Icons.movie_outlined) return '视频';
  if (icon == Icons.audiotrack_outlined) return '音频';
  if (icon == Icons.picture_as_pdf_outlined) return 'PDF';
  return '文档或其他资料';
}

IconData _previewIcon(String mimeType, String fileName) {
  if (mimeType.startsWith('video/')) {
    return Icons.movie_outlined;
  }
  if (mimeType.startsWith('audio/')) {
    return Icons.graphic_eq_rounded;
  }
  final lower = fileName.toLowerCase();
  if (mimeType == 'application/pdf' || lower.endsWith('.pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  if (mimeType.startsWith('application/')) {
    return Icons.article_outlined;
  }
  return Icons.attach_file;
}

String _previewType(String mimeType, String fileName) {
  if (mimeType.startsWith('video/')) {
    return '视频附件';
  }
  if (mimeType.startsWith('audio/')) {
    return '音频附件';
  }
  final lower = fileName.toLowerCase();
  if (mimeType == 'application/pdf' || lower.endsWith('.pdf')) {
    return 'PDF 文件';
  }
  if (_isWordDocument(mimeType, lower)) {
    return 'Word 文档';
  }
  return '附件文件';
}

String _previewLimitation(String mimeType, String fileName) {
  if (mimeType.startsWith('video/')) {
    return '文件已保存在本机；此页面提供文件信息预览，视频播放器尚未接入。';
  }
  if (mimeType.startsWith('audio/')) {
    return '文件已保存在本机；此页面提供文件信息预览，音频播放器尚未接入。';
  }
  if (mimeType == 'application/pdf' ||
      fileName.toLowerCase().endsWith('.pdf')) {
    return '文件已保存在本机，可使用应用内 PDF 查看器打开。';
  }
  if (_isWordDocument(mimeType, fileName.toLowerCase())) {
    return 'DOCX 以纯文本预览，格式和图片会简化；旧版 DOC 不支持正文预览。';
  }
  return '当前页面显示文件信息；此格式没有内嵌预览器。';
}

String _legacyPreviewMessage(LegacyAssetModel asset) =>
    _previewLimitation(asset.mimeType, _legacyFileName(asset));

String _legacyFileName(LegacyAssetModel asset) {
  final source = asset.originalPath.trim().isNotEmpty
      ? asset.originalPath
      : asset.relativePath;
  final name = source.replaceAll('\\', '/').split('/').last;
  return name.isEmpty || !name.contains('.') ? asset.title : name;
}

bool _isPdfAttachment(String mimeType, String fileName) =>
    mimeType.toLowerCase() == 'application/pdf' ||
    fileName.toLowerCase().trim().endsWith('.pdf');

bool _isWordDocument(String mimeType, String lowerFileName) =>
    lowerFileName.endsWith('.doc') ||
    lowerFileName.endsWith('.docx') ||
    mimeType.toLowerCase() == 'application/msword' ||
    mimeType.toLowerCase() ==
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

String _planMediaRole(String mimeType) {
  if (mimeType == 'application/pdf' ||
      mimeType ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
    return 'document';
  }
  return switch (mimeType.split('/').first) {
    'image' => 'photo',
    'video' => 'video',
    'audio' => 'audio',
    _ => 'attachment',
  };
}

IconData _planAttachmentIcon(MediaAssetModel asset) {
  if (asset.mimeType.startsWith('image/')) return Icons.image_outlined;
  if (asset.mimeType.startsWith('video/')) return Icons.movie_outlined;
  if (asset.mimeType.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (_isPdfAttachment(asset.mimeType, asset.fileName)) {
    return Icons.picture_as_pdf_outlined;
  }
  if (_isWordDocument(asset.mimeType, asset.fileName.toLowerCase())) {
    return Icons.article_outlined;
  }
  return Icons.attach_file;
}

String _formatPlanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
