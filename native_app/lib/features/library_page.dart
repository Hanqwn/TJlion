import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/media_store.dart';
import 'document_viewer.dart';
import 'media_viewer.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final MediaStore _mediaStore;
  final TextEditingController _searchController = TextEditingController();
  List<MediaAssetModel> _attachments = const [];
  List<LegacyAssetModel> _historicalFiles = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _mediaStore = MediaStore(
      supportDirectory: widget.repository.supportDirectory,
    );
    _reload();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _attachments = widget.repository.getMediaAssets();
      _historicalFiles = widget.repository.getLegacyAssets();
    });
  }

  List<MediaAssetModel> get _visibleAttachments {
    if (_query.isEmpty) return _attachments;
    final query = _query.toLowerCase();
    return _attachments
        .where(
          (asset) =>
              asset.title.toLowerCase().contains(query) ||
              asset.fileName.toLowerCase().contains(query) ||
              asset.ownerType.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  List<LegacyAssetModel> get _visibleHistoricalFiles {
    if (_query.isEmpty) return _historicalFiles;
    final query = _query.toLowerCase();
    return _historicalFiles
        .where(
          (asset) =>
              asset.title.toLowerCase().contains(query) ||
              asset.category.toLowerCase().contains(query) ||
              asset.groupName.toLowerCase().contains(query) ||
              asset.relativePath.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _openAttachment(MediaAssetModel asset) async {
    final file = await _mediaStore.resolveFile(asset.mediaKey);
    if (!mounted) return;
    if (file == null) {
      _showMessage('本机找不到这个附件。可在“设置”中重新导入媒体文件夹。');
      return;
    }
    await _openFile(
      file: file,
      title: asset.title,
      fileName: asset.fileName,
      mimeType: asset.mimeType,
      mediaAsset: asset,
    );
  }

  Future<void> _openHistoricalFile(LegacyAssetModel asset) async {
    final file = await widget.repository.legacyAssetFile(asset.id);
    if (!mounted) return;
    if (file == null) {
      _showMessage('这份历史资料还没有导入本机文件。请先在“设置”中导入媒体文件夹。');
      return;
    }
    final mediaAsset = MediaAssetModel(
      id: asset.id,
      mediaKey: asset.mediaKey,
      ownerType: 'legacy',
      ownerId: asset.id,
      role: 'reference',
      title: asset.title,
      fileName: p.basename(asset.relativePath),
      mimeType: asset.mimeType,
      fileSize: asset.fileSize,
      relativePath: 'media/${asset.mediaKey}',
      createdAt: '',
    );
    await _openFile(
      file: file,
      title: asset.title,
      fileName: p.basename(asset.relativePath),
      mimeType: asset.mimeType,
      mediaAsset: mediaAsset,
    );
  }

  Future<void> _openFile({
    required File file,
    required String title,
    required String fileName,
    required String mimeType,
    required MediaAssetModel mediaAsset,
  }) async {
    final extension = p.extension(fileName).toLowerCase();
    if (extension == '.pdf' ||
        extension == '.docx' ||
        extension == '.doc' ||
        mimeType == 'application/pdf' ||
        mimeType ==
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => DocumentViewer(
            file: file,
            title: title,
            fileName: fileName,
            mimeType: mimeType,
          ),
        ),
      );
      return;
    }
    await showMediaViewer(
      context: context,
      mediaStore: _mediaStore,
      asset: mediaAsset,
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  IconData _iconFor(String name, String mimeType) {
    final extension = p.extension(name).toLowerCase();
    if (mimeType.startsWith('image/')) return Icons.image_outlined;
    if (mimeType.startsWith('video/')) return Icons.play_circle_outline;
    if (mimeType.startsWith('audio/')) return Icons.audio_file_outlined;
    if (extension == '.pdf') return Icons.picture_as_pdf_outlined;
    if (extension == '.docx' || extension == '.doc') {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  Widget _buildAttachmentList() {
    final items = _visibleAttachments;
    if (items.isEmpty) {
      return _EmptyLibraryMessage(
        icon: Icons.attach_file,
        title: _query.isEmpty ? '还没有附件' : '没有匹配的附件',
        message: _query.isEmpty ? '活动、套路和文字记录的媒体附件会出现在这里。' : '换个关键词试试。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: items.length,
      separatorBuilder: (context, index) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final asset = items[index];
        return Card(
          elevation: 0,
          child: ListTile(
            leading: Icon(_iconFor(asset.fileName, asset.mimeType)),
            title: Text(asset.title),
            subtitle: Text(
              '${asset.fileName} · ${asset.ownerType} · ${_formatBytes(asset.fileSize)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openAttachment(asset),
          ),
        );
      },
    );
  }

  Widget _buildHistoricalList() {
    final items = _visibleHistoricalFiles;
    if (items.isEmpty) {
      return _EmptyLibraryMessage(
        icon: Icons.folder_open_outlined,
        title: _query.isEmpty ? '还没有历史资料索引' : '没有匹配的历史资料',
        message: _query.isEmpty
            ? '导入数据库备份后，历史资料条目会出现在这里。原始文件需要从媒体文件夹另行导入。'
            : '换个关键词试试。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: items.length,
      separatorBuilder: (context, index) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final asset = items[index];
        final fileName = p.basename(asset.relativePath);
        return Card(
          elevation: 0,
          child: ListTile(
            leading: Icon(_iconFor(fileName, asset.mimeType)),
            title: Text(asset.title),
            subtitle: Text(
              '${asset.category} · ${asset.groupName.isEmpty ? fileName : asset.groupName} · ${_formatBytes(asset.fileSize)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openHistoricalFile(asset),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '资料库与附件',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '浏览本机附件和历史资料索引。缺少的原始文件可从“设置”导入。',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索标题、文件名或分类',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: '附件'),
              Tab(text: '历史资料'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [_buildAttachmentList(), _buildHistoricalList()],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibraryMessage extends StatelessWidget {
  const _EmptyLibraryMessage({
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
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 38, color: colors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
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
