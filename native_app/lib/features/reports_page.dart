import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/media_store.dart';
import 'document_viewer.dart';
import 'media_viewer.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  late final MediaStore _mediaStore;
  final TextEditingController _searchController = TextEditingController();
  List<DocumentModel> _documents = const [];
  List<LegacyAssetModel> _legacyAssets = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _mediaStore = MediaStore(
      supportDirectory: widget.repository.supportDirectory,
    );
    _legacyAssets = widget.repository.getLegacyAssets();
    _loadDocuments();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadDocuments() {
    setState(() => _documents = widget.repository.getDocuments());
  }

  List<DocumentModel> get _visibleDocuments {
    if (_query.isEmpty) return _documents;
    final needle = _query.toLowerCase();
    return _documents
        .where((document) {
          return document.title.toLowerCase().contains(needle) ||
              document.documentType.toLowerCase().contains(needle) ||
              document.content.toLowerCase().contains(needle);
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

  Future<void> _editDocument([DocumentModel? document]) async {
    final draft = await showDialog<_DocumentDraft>(
      context: context,
      builder: (context) => _DocumentEditorDialog(
        document: document,
        legacyAssets: _legacyAssets,
        linkedAsset: _legacyAsset(document?.legacyAssetId),
      ),
    );
    if (draft == null || !mounted) return;
    try {
      int? createdId;
      if (document == null) {
        createdId = widget.repository.addDocument(
          title: draft.title,
          documentType: draft.documentType,
          documentDate: draft.documentDate,
          content: draft.content,
          legacyAssetId: draft.legacyAssetId,
        );
      } else {
        widget.repository.updateDocument(
          DocumentModel(
            id: document.id,
            title: draft.title,
            documentType: draft.documentType,
            documentDate: draft.documentDate,
            content: draft.content,
            legacyAssetId: draft.legacyAssetId,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt,
          ),
        );
      }
      _loadDocuments();
      _showMessage(document == null ? '记录已添加' : '记录已更新');
      if (document == null) {
        final created = widget.repository.getDocument(createdId!);
        if (created != null && mounted) _showDetails(created);
      }
    } catch (error) {
      _showMessage('保存失败：$error');
    }
  }

  Future<void> _deleteDocument(DocumentModel document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除记录？'),
        content: Text('确定删除“${document.title}”吗？历史资料库中的原始附件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      for (final asset in widget.repository.getMediaAssets(
        ownerType: 'document',
        ownerId: document.id,
      )) {
        await widget.repository.deleteMediaAsset(asset.id);
        await _mediaStore.removeAsset(asset.mediaKey);
      }
      widget.repository.deleteDocument(document.id);
      _loadDocuments();
      _showMessage('记录已删除');
    } catch (error) {
      _showMessage('删除失败：$error');
    }
  }

  Future<void> _showDetails(DocumentModel document) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ReportDetailsDialog(
        repository: widget.repository,
        mediaStore: _mediaStore,
        document: document,
        linkedAsset: _legacyAsset(document.legacyAssetId),
      ),
    );
    if (mounted) _loadDocuments();
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
    final documents = _visibleDocuments;

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
                              '通讯与总结',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '编写通讯稿、会议纪要、活动总结和其他文字记录。',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: () => _editDocument(),
                        icon: const Icon(Icons.add),
                        label: const Text('新建记录'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '搜索标题、分类或正文',
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
                  if (documents.isEmpty)
                    _ReportsEmptyState(hasQuery: _query.isNotEmpty)
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: documents.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: 252,
                      ),
                      itemBuilder: (context, index) {
                        final document = documents[index];
                        return _ReportCard(
                          document: document,
                          linkedAsset: _legacyAsset(document.legacyAssetId),
                          mediaCount: widget.repository
                              .getMediaAssets(
                                ownerType: 'document',
                                ownerId: document.id,
                              )
                              .length,
                          onOpen: () => _showDetails(document),
                          onEdit: () => _editDocument(document),
                          onDelete: () => _deleteDocument(document),
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

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.document,
    required this.linkedAsset,
    required this.mediaCount,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final DocumentModel document;
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
                      Icons.article_outlined,
                      color: colors.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          document.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          [
                            document.documentType,
                            _displayDate(document.documentDate),
                          ].where((value) => value.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.primary),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '记录操作',
                    onSelected: (value) {
                      if (value == 'edit') onEdit();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑记录')),
                      PopupMenuItem(value: 'delete', child: Text('删除记录')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Text(
                  document.content.isEmpty ? '还没有填写正文。' : document.content,
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
                    Icons.attach_file_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      linkedAsset?.title ?? '无历史资料附件',
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

class _ReportsEmptyState extends StatelessWidget {
  const _ReportsEmptyState({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 70, horizontal: 20),
        child: Column(
          children: [
            Icon(Icons.article_outlined, size: 52, color: colors.primary),
            const SizedBox(height: 12),
            Text(
              hasQuery ? '没有匹配的记录' : '还没有通讯或总结记录',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery ? '换个关键词试试。' : '新建通讯稿、会议总结或活动记录。',
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

class _DocumentEditorDialog extends StatefulWidget {
  const _DocumentEditorDialog({
    required this.document,
    required this.legacyAssets,
    required this.linkedAsset,
  });

  final DocumentModel? document;
  final List<LegacyAssetModel> legacyAssets;
  final LegacyAssetModel? linkedAsset;

  @override
  State<_DocumentEditorDialog> createState() => _DocumentEditorDialogState();
}

class _DocumentEditorDialogState extends State<_DocumentEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _date;
  late final TextEditingController _content;
  late String _documentType;
  int? _legacyAssetId;

  static const _defaultTypes = ['通讯稿', '会议总结', '活动总结', '其他记录'];

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.document?.title ?? '');
    _date = TextEditingController(text: widget.document?.documentDate ?? '');
    _content = TextEditingController(text: widget.document?.content ?? '');
    _documentType = widget.document?.documentType.isNotEmpty == true
        ? widget.document!.documentType
        : _defaultTypes.first;
    _legacyAssetId = widget.document?.legacyAssetId;
  }

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(_date.text) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      helpText: '选择记录日期',
    );
    if (picked != null) _date.text = _formatDate(picked);
  }

  Future<void> _chooseAsset() async {
    final selectedId = await showDialog<int>(
      context: context,
      builder: (context) => _ReportLegacyPickerDialog(
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
      _DocumentDraft(
        title: _title.text.trim(),
        documentType: _documentType,
        documentDate: _date.text.trim(),
        content: _content.text.trim(),
        legacyAssetId: _legacyAssetId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final types = <String>{
      ..._defaultTypes,
      _documentType,
    }.toList(growable: false);
    final selected =
        widget.legacyAssets
            .where((item) => item.id == _legacyAssetId)
            .firstOrNull ??
        (widget.linkedAsset?.id == _legacyAssetId ? widget.linkedAsset : null);
    return AlertDialog(
      title: Text(widget.document == null ? '新建文字记录' : '编辑文字记录'),
      content: SizedBox(
        width: 600,
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
                    labelText: '标题 *',
                    prefixIcon: Icon(Icons.title),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入标题' : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _documentType,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '记录类型',
                          prefixIcon: Icon(Icons.category_outlined),
                        ),
                        items: types
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _documentType = value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _date,
                        readOnly: true,
                        decoration: InputDecoration(
                          labelText: '日期',
                          prefixIcon: const Icon(Icons.calendar_today_outlined),
                          suffixIcon: IconButton(
                            onPressed: _pickDate,
                            tooltip: '选择日期',
                            icon: const Icon(Icons.event_outlined),
                          ),
                        ),
                        onTap: _pickDate,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _content,
                  minLines: 7,
                  maxLines: 14,
                  decoration: const InputDecoration(
                    labelText: '正文',
                    hintText: '记录通讯内容、会议讨论、结论或后续事项。',
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
                        : _legacyReportIcon(selected),
                  ),
                  label: Text(selected?.title ?? '关联历史资料库文件'),
                ),
                if (selected != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_legacyReportFileName(selected)} · ${_legacyReportKind(selected)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '历史资料库中的 PDF 可预览，DOCX 显示提取文字；图片、视频和音频可在记录详情中添加。',
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
        FilledButton(onPressed: _save, child: const Text('保存记录')),
      ],
    );
  }
}

class _DocumentDraft {
  const _DocumentDraft({
    required this.title,
    required this.documentType,
    required this.documentDate,
    required this.content,
    required this.legacyAssetId,
  });

  final String title;
  final String documentType;
  final String documentDate;
  final String content;
  final int? legacyAssetId;
}

class _ReportDetailsDialog extends StatefulWidget {
  const _ReportDetailsDialog({
    required this.repository,
    required this.mediaStore,
    required this.document,
    required this.linkedAsset,
  });

  final LionRepository repository;
  final MediaStore mediaStore;
  final DocumentModel document;
  final LegacyAssetModel? linkedAsset;

  @override
  State<_ReportDetailsDialog> createState() => _ReportDetailsDialogState();
}

class _ReportDetailsDialogState extends State<_ReportDetailsDialog> {
  late List<MediaAssetModel> _mediaAssets;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _mediaAssets = widget.repository.getMediaAssets(
      ownerType: 'document',
      ownerId: widget.document.id,
    );
  }

  Future<void> _addMedia() async {
    setState(() => _busy = true);
    try {
      final ref = await widget.mediaStore.pickMedia(dialogTitle: '选择照片、视频或音频');
      if (ref == null || !mounted) return;
      try {
        widget.repository.putMediaAssetMetadata(
          mediaKey: ref.mediaKey,
          relativePath: ref.relativePath,
          ownerType: 'document',
          ownerId: widget.document.id,
          role: _reportMediaRole(ref.mimeType),
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
      if (_isWordReport(ref.mimeType, ref.fileName.toLowerCase()) &&
          ref.fileSize > 16 * 1024 * 1024) {
        await widget.mediaStore.removeAsset(ref.mediaKey);
        throw const FormatException('DOCX 文件超过 16 MB，无法在应用内预览。');
      }
      try {
        widget.repository.putMediaAssetMetadata(
          mediaKey: ref.mediaKey,
          relativePath: ref.relativePath,
          ownerType: 'document',
          ownerId: widget.document.id,
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
    final confirmed = await _confirmReportRemove(context, asset.fileName);
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
    if (_isPdfReport(asset.mimeType, asset.fileName) ||
        _isWordReport(asset.mimeType, asset.fileName.toLowerCase())) {
      final file = await widget.mediaStore.resolveFile(asset.mediaKey);
      if (!mounted) return;
      if (file == null) {
        await showDialog<void>(
          context: context,
          builder: (context) => _ReportFilePreviewDialog(
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
    final fileName = _legacyReportFileName(asset);
    if (file != null &&
        (_isPdfReport(asset.mimeType, fileName) ||
            _isWordReport(asset.mimeType, fileName.toLowerCase()))) {
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
      builder: (context) => _ReportFilePreviewDialog(
        title: asset.title,
        fileName: fileName,
        mimeType: asset.mimeType,
        fileSize: asset.fileSize,
        file: file,
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
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 800),
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
                          widget.document.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            widget.document.documentType,
                            _displayDate(widget.document.documentDate),
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
                  Text(
                    '正文',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    widget.document.content.isEmpty
                        ? '暂无正文内容。'
                        : widget.document.content,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.55,
                      color: widget.document.content.isEmpty
                          ? colors.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '附件与媒体',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _addMedia,
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
                  const SizedBox(height: 6),
                  Text(
                    '可添加照片、视频、音频，也可导入 PDF/DOCX。DOCX 以纯文本预览。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  if (widget.linkedAsset != null) ...[
                    const SizedBox(height: 12),
                    _ReportLegacyTile(
                      asset: widget.linkedAsset!,
                      onOpen: _previewLegacy,
                    ),
                  ],
                  if (_mediaAssets.isEmpty && widget.linkedAsset == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        '尚未添加附件。',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ..._mediaAssets.map(
                    (asset) => _ReportMediaTile(
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

class _ReportLegacyTile extends StatelessWidget {
  const _ReportLegacyTile({required this.asset, required this.onOpen});

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
            _legacyReportIcon(asset),
            color: colors.onSecondaryContainer,
          ),
        ),
        title: Text(asset.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_legacyReportFileName(asset)} · ${_legacyReportKind(asset)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.open_in_new),
      ),
    );
  }
}

class _ReportMediaTile extends StatelessWidget {
  const _ReportMediaTile({
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
    final icon = _reportAttachmentIcon(asset);
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
          '${asset.fileName} · ${_formatReportBytes(asset.fileSize)}',
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

class _ReportFilePreviewDialog extends StatelessWidget {
  const _ReportFilePreviewDialog({
    required this.title,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.file,
  });

  final String title;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final File? file;

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
              subtitle: Text('$fileName · ${_formatReportBytes(fileSize)}'),
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
                                  _reportPreviewIcon(mimeType, fileName),
                                  size: 48,
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _reportPreviewType(mimeType, fileName),
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 7),
                              Text(fileName, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              Text(
                                _reportPreviewLimitation(mimeType, fileName),
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

class _ReportLegacyPickerDialog extends StatefulWidget {
  const _ReportLegacyPickerDialog({
    required this.assets,
    required this.selectedAssetId,
  });

  final List<LegacyAssetModel> assets;
  final int? selectedAssetId;

  @override
  State<_ReportLegacyPickerDialog> createState() =>
      _ReportLegacyPickerDialogState();
}

class _ReportLegacyPickerDialogState extends State<_ReportLegacyPickerDialog> {
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
        .where(
          (asset) =>
              asset.title.toLowerCase().contains(_query) ||
              _legacyReportFileName(asset).toLowerCase().contains(_query) ||
              asset.category.toLowerCase().contains(_query) ||
              asset.groupName.toLowerCase().contains(_query),
        )
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
                          leading: Icon(_legacyReportIcon(asset)),
                          title: Text(
                            asset.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_legacyReportFileName(asset)} · ${_legacyReportKind(asset)}',
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

Future<bool?> _confirmReportRemove(BuildContext context, String name) =>
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

IconData _legacyReportIcon(LegacyAssetModel asset) {
  final name = _legacyReportFileName(asset).toLowerCase();
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

String _legacyReportKind(LegacyAssetModel asset) {
  final icon = _legacyReportIcon(asset);
  if (icon == Icons.image_outlined) return '照片';
  if (icon == Icons.movie_outlined) return '视频';
  if (icon == Icons.audiotrack_outlined) return '音频';
  if (icon == Icons.picture_as_pdf_outlined) return 'PDF';
  return 'Word/其他文档';
}

IconData _reportPreviewIcon(String mimeType, String fileName) {
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
  if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
    return Icons.article_outlined;
  }
  return Icons.attach_file;
}

String _reportPreviewType(String mimeType, String fileName) {
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
  if (_isWordReport(mimeType, lower)) {
    return 'Word 文档';
  }
  return '附件文件';
}

String _reportPreviewLimitation(String mimeType, String fileName) {
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
  if (_isWordReport(mimeType, fileName.toLowerCase())) {
    return 'DOCX 以纯文本预览，格式和图片会简化；旧版 DOC 不支持正文预览。';
  }
  return '当前页面显示文件信息；此格式没有内嵌预览器。';
}

String _reportMediaRole(String mimeType) {
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

IconData _reportAttachmentIcon(MediaAssetModel asset) {
  if (asset.mimeType.startsWith('image/')) return Icons.image_outlined;
  if (asset.mimeType.startsWith('video/')) return Icons.movie_outlined;
  if (asset.mimeType.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (_isPdfReport(asset.mimeType, asset.fileName)) {
    return Icons.picture_as_pdf_outlined;
  }
  if (_isWordReport(asset.mimeType, asset.fileName.toLowerCase())) {
    return Icons.article_outlined;
  }
  return Icons.attach_file;
}

String _legacyReportFileName(LegacyAssetModel asset) {
  final source = asset.originalPath.trim().isNotEmpty
      ? asset.originalPath
      : asset.relativePath;
  final name = source.replaceAll('\\', '/').split('/').last;
  return name.isEmpty || !name.contains('.') ? asset.title : name;
}

bool _isPdfReport(String mimeType, String fileName) =>
    mimeType.toLowerCase() == 'application/pdf' ||
    fileName.toLowerCase().trim().endsWith('.pdf');

bool _isWordReport(String mimeType, String lowerFileName) =>
    lowerFileName.endsWith('.doc') ||
    lowerFileName.endsWith('.docx') ||
    mimeType.toLowerCase() == 'application/msword' ||
    mimeType.toLowerCase() ==
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

String _displayDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
}

String _formatDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _formatReportBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
