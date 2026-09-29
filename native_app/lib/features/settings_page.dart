import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/lion_repository.dart';
import '../services/media_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final MediaStore _mediaStore;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _mediaStore = MediaStore(
      supportDirectory: widget.repository.supportDirectory,
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showMessage('操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _exportDatabase() async {
    final folder = await _mediaStore.pickBundleDirectory(
      dialogTitle: '选择数据库备份保存文件夹',
    );
    if (folder == null) return;
    await folder.create(recursive: true);

    final stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final baseName = 'lion-manager-' + stamp;
    var suffix = 0;
    var name = baseName + '.sqlite3';
    var destination = File(p.join(folder.path, name));
    while (await destination.exists()) {
      suffix++;
      name = baseName + '-' + suffix.toString() + '.sqlite3';
      destination = File(p.join(folder.path, name));
    }

    final exported = await widget.repository.exportDatabase(destination);
    _showMessage('数据库备份已导出：' + exported.path);
  }

  Future<void> _importDatabase() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择 Lion Manager 数据库备份',
      type: FileType.custom,
      allowedExtensions: const ['sqlite3', 'sqlite', 'db'],
    );
    if (picked == null) return;
    final path = picked.path;
    if (path == null || path.isEmpty) {
      throw const FormatException('无法读取所选数据库文件的位置。');
    }

    final fileName = p.basename(path);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('导入数据库备份？'),
        content: Text(
          '将使用“' + fileName + '”替换此设备当前的本地数据库。应用会先验证数据库并执行所需迁移；如果文件无效，当前数据会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await widget.repository.importDatabase(File(path));
    _showMessage('数据库导入成功，已载入本地资料。');
  }

  Future<Directory?> _chooseFolder(String title) {
    return _mediaStore.pickBundleDirectory(dialogTitle: title);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    return LayoutBuilder(
      builder: (context, _) {
        final padding = width < 560 ? 18.0 : 30.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(padding, 22, padding, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(
                          Icons.tune_rounded,
                          size: 27,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '设置与数据',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '资料保存在本机，可随时导出备份或迁移到其他设备。',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: 20),
                  Card(
                    elevation: 0,
                    color: colors.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.storage_outlined,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '本地数据库',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '手动备份或从另一设备迁移 Lion Manager 的 SQLite 数据。',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            widget.repository.databasePath,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _run(_exportDatabase),
                                icon: const Icon(Icons.file_upload_outlined),
                                label: const Text('导出数据库备份'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => _run(_importDatabase),
                                icon: const Icon(Icons.file_download_outlined),
                                label: const Text('导入数据库备份'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildAttachmentCard(context),
                  const SizedBox(height: 16),
                  _LocalStorageNote(colors: colors),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _exportMediaBundle() async {
    final parent = await _chooseFolder('选择附件目录包保存位置');
    if (parent == null) return;
    final stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final bundle = await _mediaStore.exportBundle(
      parentDirectory: parent,
      bundleName: 'lion-media-' + stamp,
    );
    _showMessage('附件目录包已导出：' + bundle.path);
  }

  Future<void> _importMediaBundle() async {
    final bundle = await _chooseFolder('选择另一设备的附件目录包');
    if (bundle == null) return;
    final assets = await _readBundleManifest(bundle, verifyFiles: true);
    if (!mounted) return;

    final count = assets.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入附件目录包？'),
        content: Text(
          '清单中有 ' +
              count.toString() +
              ' 个附件。相同附件会跳过；如果清单与本机存在同键冲突，导入会失败且不覆盖本机文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await _mediaStore.importBundle(bundleDirectory: bundle);
    _showMessage(
      '附件导入完成：新增 ' +
          result.importedCount.toString() +
          ' 个，跳过 ' +
          result.skippedCount.toString() +
          ' 个。',
    );
  }

  Future<void> _compareMediaBundles() async {
    final otherBundle = await _chooseFolder('选择另一设备的附件目录包');
    if (otherBundle == null) return;

    final otherAssets = await _readBundleManifest(
      otherBundle,
      verifyFiles: true,
    );
    final localAssets = await _mediaStore.listAssets();
    final otherByKey = {for (final asset in otherAssets) asset.mediaKey: asset};
    final missing = localAssets
        .where((asset) => !otherByKey.containsKey(asset.mediaKey))
        .toList(growable: false);
    final conflicts = localAssets.where((asset) {
      final other = otherByKey[asset.mediaKey];
      return other != null && !_sameMetadata(asset, other);
    }).length;

    if (missing.isEmpty) {
      final message = conflicts == 0
          ? '另一设备已包含本机全部 ' + localAssets.length.toString() + ' 个附件。'
          : '没有缺少的附件；另有 ' + conflicts.toString() + ' 个同键附件元数据不同，本次不会覆盖。';
      _showMessage(message);
      return;
    }
    if (!mounted) return;

    final missingCount = missing.length;
    final totalBytes = missing.fold<int>(
      0,
      (sum, asset) => sum + asset.fileSize,
    );
    final conflictNote = conflicts == 0
        ? ''
        : '\n\n另有 ' + conflicts.toString() + ' 个同键元数据不同的附件，不会包含在补传包中。';
    final confirmationText =
        '另一设备缺少 ' +
        missingCount.toString() +
        ' 个附件（' +
        _formatBytes(totalBytes) +
        '）。将只导出这些附件，并附上可供导入的清单。' +
        conflictNote;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('比对完成'),
        content: Text(confirmationText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.folder_outlined),
            label: const Text('选择导出位置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final parent = await _chooseFolder('选择缺少附件的导出位置');
    if (parent == null) return;
    final exported = await _exportSelectedAssets(missing, parent);
    _showMessage('已导出 ' + missingCount.toString() + ' 个缺少的附件：' + exported.path);
  }

  Future<List<MediaFileRef>> _readBundleManifest(
    Directory bundle, {
    required bool verifyFiles,
  }) async {
    final manifest = File(p.join(bundle.path, 'media-index.json'));
    final manifestType = await FileSystemEntity.type(
      manifest.path,
      followLinks: false,
    );
    if (manifestType != FileSystemEntityType.file) {
      throw const FormatException('所选目录中没有 media-index.json 清单。');
    }
    if (await manifest.length() > 8 * 1024 * 1024) {
      throw const FormatException('附件清单超过 8 MiB，无法安全读取。');
    }

    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'lion_media_index' ||
        decoded['version'] != 1 ||
        decoded['assets'] is! List<dynamic>) {
      throw const FormatException('附件清单格式不受支持。');
    }

    final assets = <MediaFileRef>[];
    final keys = <String>{};
    for (final raw in decoded['assets'] as List<dynamic>) {
      if (raw is! Map) {
        throw const FormatException('附件清单项目格式错误。');
      }
      final asset = MediaFileRef.fromJson(
        Map<String, dynamic>.from(raw),
        maxFileSizeBytes: _mediaStore.maxFileSizeBytes,
      );
      if (!keys.add(asset.mediaKey)) {
        throw FormatException('附件清单中有重复键：' + asset.mediaKey);
      }
      assets.add(asset);
    }

    if (verifyFiles && assets.isNotEmpty) {
      final mediaDirectory = Directory(p.join(bundle.path, 'media'));
      final directoryType = await FileSystemEntity.type(
        mediaDirectory.path,
        followLinks: false,
      );
      if (directoryType != FileSystemEntityType.directory) {
        throw const FormatException('附件清单对应的 media 文件夹不存在。');
      }
      for (final asset in assets) {
        final file = File(p.join(mediaDirectory.path, asset.mediaKey));
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type != FileSystemEntityType.file ||
            await file.length() != asset.fileSize) {
          throw FormatException('附件文件缺失或大小不符：' + asset.fileName);
        }
      }
    }
    return List<MediaFileRef>.unmodifiable(assets);
  }

  Future<Directory> _exportSelectedAssets(
    List<MediaFileRef> assets,
    Directory parentDirectory,
  ) async {
    final parent = parentDirectory.absolute;
    await parent.create(recursive: true);
    final mediaRoot = p.absolute(
      p.join(widget.repository.supportDirectory.path, 'media'),
    );
    final parentPath = p.absolute(parent.path);
    if (p.equals(parentPath, mediaRoot) || p.isWithin(mediaRoot, parentPath)) {
      throw ArgumentError('请选择本机附件存储目录之外的位置。');
    }

    final stamp = DateTime.now().millisecondsSinceEpoch.toString();
    var name = 'lion-media-missing-' + stamp;
    var finalDirectory = Directory(p.join(parent.path, name));
    var suffix = 1;
    while (await finalDirectory.exists()) {
      name = 'lion-media-missing-' + stamp + '-' + suffix.toString();
      finalDirectory = Directory(p.join(parent.path, name));
      suffix++;
    }
    final staging = Directory(p.join(parent.path, '.' + name + '.partial'));
    final stagingMedia = Directory(p.join(staging.path, 'media'));
    await stagingMedia.create(recursive: true);

    try {
      for (final asset in assets) {
        final source = await _mediaStore.resolveFile(asset.mediaKey);
        if (source == null || await source.length() != asset.fileSize) {
          throw FormatException('本机附件缺失或大小不符：' + asset.fileName);
        }
        final destination = File(p.join(stagingMedia.path, asset.mediaKey));
        await source.copy(destination.path);
        if (await destination.length() != asset.fileSize) {
          throw FormatException('附件复制后大小不符：' + asset.fileName);
        }
      }

      final index = <String, Object?>{
        'format': 'lion_media_index',
        'version': 1,
        'assets': assets.map((asset) => asset.toJson()).toList(),
      };
      await File(p.join(staging.path, 'media-index.json'))
          .writeAsString(jsonEncode(index), flush: true);
      await staging.rename(finalDirectory.path);
      return finalDirectory;
    } catch (_) {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
  }

  bool _sameMetadata(MediaFileRef left, MediaFileRef right) {
    return left.mediaKey == right.mediaKey &&
        left.fileName == right.fileName &&
        left.mimeType == right.mimeType &&
        left.fileSize == right.fileSize &&
        left.relativePath == right.relativePath;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      final kib = (bytes / 1024).toStringAsFixed(1);
      return kib + ' KiB';
    }
    final mib = (bytes / (1024 * 1024)).toStringAsFixed(1);
    return mib + ' MiB';
  }

  Widget _buildAttachmentCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.perm_media_outlined, color: colors.primary),
                const SizedBox(width: 10),
                Text(
                  '附件迁移',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '附件以目录包保存，包含 media-index.json 清单与 media 文件夹，不压缩。',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _run(_exportMediaBundle),
                  icon: const Icon(Icons.folder_zip_outlined),
                  label: const Text('导出全部附件'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _run(_importMediaBundle),
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('导入附件目录包'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _run(_compareMediaBundles),
                  icon: const Icon(Icons.compare_arrows_rounded),
                  label: const Text('比对另一设备'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalStorageNote extends StatelessWidget {
  const _LocalStorageNote({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.offline_bolt_outlined, color: colors.onSecondaryContainer),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '迁移由你选择本机文件夹完成，不经过服务器。建议先导入数据库，再导入完整附件包；若对方已有附件包，可比对清单后只补传缺少的文件。',
            ),
          ),
        ],
      ),
    );
  }
}
