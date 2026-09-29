import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

/// Stores media bytes as files under application support, never in SQLite.
///
/// Add these dependencies to the native Flutter app:
///
/// ```yaml
/// file_picker: ^13.1.0
/// path_provider: ^2.1.6
/// ```
///
/// Those current versions require Flutter 3.38 / Dart 3.10. The local layout
/// is `Application Support/media/<32-hex-key>` plus
/// `Application Support/media-index.json`. The key-only filename matches the
/// native repository's `MediaAssetModel.relativePath` value `media/<key>`.
///
/// `pickBundleDirectory` uses the platform directory picker where available.
/// The app-private support directory is not user-pickable on Android or iOS;
/// callers must choose a shared destination for bundles. Android's SAF also
/// restricts some protected locations (including Android/data and certain
/// storage roots on newer Android versions). File-picker directory selection
/// is unavailable on web.
class MediaStore {
  MediaStore({
    Directory? supportDirectory,
    this.maxFileSizeBytes = defaultMaxFileSizeBytes,
  }) : _supportDirectory = supportDirectory {
    if (maxFileSizeBytes <= 0) {
      throw ArgumentError.value(
        maxFileSizeBytes,
        'maxFileSizeBytes',
        'Must be positive.',
      );
    }
  }

  static const int defaultMaxFileSizeBytes = 8 * 1024 * 1024 * 1024;
  static const int _maxIndexBytes = 8 * 1024 * 1024;
  static const int _indexVersion = 1;
  static const String _indexFormat = 'lion_media_index';
  static const String _relativeMediaDirectory = 'media';

  static const List<String> supportedExtensions = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'avif',
    'tif',
    'tiff',
    'mp3',
    'aac',
    'm4a',
    'wav',
    'flac',
    'ogg',
    'opus',
    'amr',
    'mp4',
    'm4v',
    'mov',
    'webm',
    'mkv',
    'avi',
    'wmv',
    'flv',
    '3gp',
  ];
  static const List<String> supportedDocumentExtensions = ['pdf', 'docx'];

  static final math.Random _secureRandom = math.Random.secure();

  final Directory? _supportDirectory;
  final int maxFileSizeBytes;
  Future<void> _mutationTail = Future<void>.value();

  /// Lets a native caller choose a media file. Cancellation returns `null`.
  Future<MediaFileRef?> pickMedia({String? dialogTitle, String? title}) async {
    _ensureNativePlatform('Media picking');
    final picked = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: supportedExtensions,
    );
    if (picked == null) return null;
    return storePickedFile(picked, title: title);
  }

  /// Opens a PDF/DOCX-only picker and stores the selected document.
  /// Cancellation returns `null`. Legacy `.doc` files are deliberately not
  /// accepted here; existing `.doc` attachments remain identifiable but are
  /// marked unsupported by document-preview code.
  Future<MediaFileRef?> importDocumentFile({
    String? dialogTitle,
    String? title,
  }) async {
    _ensureNativePlatform('Document import');
    final picked = await FilePicker.pickFile(
      dialogTitle: dialogTitle ?? '选择 PDF 或 DOCX 文件',
      type: FileType.custom,
      allowedExtensions: supportedDocumentExtensions,
    );
    if (picked == null) return null;
    final fileName = _safeBaseName(picked.name);
    if (!_isSupportedDocumentName(fileName)) {
      throw FormatException('Only .pdf and .docx documents can be imported.');
    }
    return storePickedFile(picked, title: title);
  }

  /// Opens the platform directory picker for choosing an import/export folder.
  /// Returns `null` when the picker is cancelled.
  Future<Directory?> pickBundleDirectory({String? dialogTitle}) async {
    _ensureNativePlatform('Directory picking');
    final path = await FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
    return path == null ? null : Directory(path);
  }

  /// Streams a picked media file into the managed store and indexes its key.
  Future<MediaFileRef> storePickedFile(PlatformFile picked, {String? title}) {
    return _exclusive(() async {
      final fileName = _safeBaseName(picked.name);
      if (!_isAllowedNewFileName(fileName)) {
        throw FormatException(
          'Unsupported media or document file type: $fileName',
        );
      }
      final mimeType = _mimeTypeForName(fileName);
      if (mimeType == null) {
        throw FormatException('Unsupported media file type: $fileName');
      }
      final declaredSize = await picked.length();
      if (declaredSize != null && declaredSize > maxFileSizeBytes) {
        throw FormatException('Media file exceeds the configured size limit.');
      }
      return _storeStream(
        picked.readAsByteStream(),
        fileName: fileName,
        mimeType: mimeType,
        title: title,
        expectedSize: declaredSize,
      );
    });
  }

  /// Streams a local source file into the managed store.
  Future<MediaFileRef> storeFile(
    File sourceFile, {
    String? fileName,
    String? mimeType,
    String? title,
  }) {
    return _exclusive(() async {
      final sourceName = fileName ?? _baseName(sourceFile.path);
      final safeName = _safeBaseName(sourceName);
      if (!_isAllowedNewFileName(safeName)) {
        throw FormatException(
          'Unsupported media or document file type: $safeName',
        );
      }
      final inferredMime = _mimeTypeForName(safeName);
      if (inferredMime == null) {
        throw FormatException('Unsupported media file type: $safeName');
      }
      if (mimeType != null && mimeType != inferredMime) {
        throw FormatException(
          'MIME type does not match the media file extension.',
        );
      }
      if (!await sourceFile.exists()) {
        throw FileSystemException(
          'Media source does not exist.',
          sourceFile.path,
        );
      }
      final sourceSize = await sourceFile.length();
      if (sourceSize > maxFileSizeBytes) {
        throw FormatException('Media file exceeds the configured size limit.');
      }
      return _storeStream(
        sourceFile.openRead(),
        fileName: safeName,
        mimeType: inferredMime,
        title: title,
        expectedSize: sourceSize,
      );
    });
  }

  /// Returns a managed local file for image, audio, or video preview.
  ///
  /// Preview widgets can use the returned file directly, for example
  /// `Image.file(file)` or a path-based audio/video controller. Invalid keys
  /// are rejected, missing files return `null`, and symbolic links are never
  /// followed.
  Future<File?> resolveFile(String mediaKey) async {
    _requireMediaKey(mediaKey);
    final mediaDirectory = await _mediaDirectory();
    final file = File(_join(mediaDirectory.path, mediaKey));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type == FileSystemEntityType.link) {
      throw FileSystemException(
        'Managed media path is a symbolic link.',
        file.path,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Managed media path is not a file.', file.path);
    }
    return file;
  }

  /// Returns the local path for a preview, or `null` when the key is missing.
  Future<String?> resolvePath(String mediaKey) async =>
      (await resolveFile(mediaKey))?.path;

  /// Removes only the managed file derived from a validated 32-hex key.
  /// The index is updated before the staged file is unlinked, and no recursive
  /// deletion is used for media assets.
  Future<bool> removeAsset(String mediaKey) {
    _requireMediaKey(mediaKey);
    return _exclusive(() async {
      final support = await _supportDir();
      final mediaDirectory = await _mediaDirectory();
      final indexFile = File(_join(support.path, 'media-index.json'));
      final assets = await _readIndex(indexFile);
      final removed = assets.remove(mediaKey);
      final target = File(_join(mediaDirectory.path, mediaKey));
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (removed == null && type == FileSystemEntityType.notFound) {
        return false;
      }
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file &&
          type != FileSystemEntityType.link) {
        throw FileSystemException(
          'Managed media path is not a file.',
          target.path,
        );
      }

      File? tombstone;
      if (type != FileSystemEntityType.notFound) {
        tombstone = File('${target.path}.${_newKey()}.deleting');
        await target.rename(tombstone.path);
      }
      try {
        await _writeIndex(indexFile, assets);
      } catch (_) {
        if (tombstone != null &&
            await FileSystemEntity.type(tombstone.path, followLinks: false) !=
                FileSystemEntityType.notFound) {
          await tombstone.rename(target.path);
        }
        rethrow;
      }
      if (tombstone != null) {
        try {
          await tombstone.delete();
        } on FileSystemException {
          // The index no longer exposes the asset; an orphan can be cleaned up
          // later without risking deletion of any unrelated path.
        }
      }
      return true;
    });
  }

  /// Lists metadata in the on-disk media index in key order.
  Future<List<MediaFileRef>> listAssets() async {
    final support = await _supportDir();
    final assets = await _readIndex(
      File(_join(support.path, 'media-index.json')),
    );
    final result = assets.values.toList()..sort(_compareRefs);
    return List<MediaFileRef>.unmodifiable(result);
  }

  /// Exports an index and streamed media files as a portable folder bundle.
  /// The selected [parentDirectory] receives a new uniquely named bundle
  /// folder containing `media-index.json` and `media/<mediaKey>` files.
  Future<Directory> exportBundle({
    required Directory parentDirectory,
    String? bundleName,
  }) {
    return _exclusive(() async {
      final parent = parentDirectory.absolute;
      await parent.create(recursive: true);
      final mediaDirectory = await _mediaDirectory();
      if (await _isSameOrChild(parent, mediaDirectory)) {
        throw ArgumentError(
          'Choose an export folder outside app media storage.',
        );
      }
      final support = await _supportDir();
      final assets = await _readIndex(
        File(_join(support.path, 'media-index.json')),
      );
      final safeBundleName = _safeBundleName(
        bundleName ?? _defaultBundleName(),
      );
      final finalDirectory = Directory(_join(parent.path, safeBundleName));
      if (await finalDirectory.exists()) {
        throw FileSystemException(
          'Export destination already exists.',
          finalDirectory.path,
        );
      }
      final staging = Directory(
        _join(parent.path, '.$safeBundleName.${_newKey()}.partial'),
      );
      final stagedMedia = Directory(_join(staging.path, 'media'));
      await stagedMedia.create(recursive: true);
      try {
        final sortedAssets = assets.values.toList()..sort(_compareRefs);
        for (final asset in sortedAssets) {
          final source = File(_join(mediaDirectory.path, asset.mediaKey));
          await _verifyManagedFile(source, asset.fileSize);
          final destination = File(_join(stagedMedia.path, asset.mediaKey));
          final copiedSize = await _copyStreamToFile(
            source.openRead(),
            destination,
            expectedSize: asset.fileSize,
          );
          if (copiedSize != asset.fileSize) {
            throw FormatException('Media size changed during bundle export.');
          }
        }
        final indexFile = File(_join(staging.path, 'media-index.json'));
        await indexFile.writeAsString(
          jsonEncode(_indexJson(assets)),
          encoding: utf8,
          flush: true,
        );
        await staging.rename(finalDirectory.path);
        return finalDirectory;
      } catch (_) {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
        rethrow;
      }
    });
  }

  /// Imports a portable folder bundle, validating all keys and per-file sizes
  /// before committing any newly copied assets to the managed directory.
  Future<MediaBundleImportResult> importBundle({
    required Directory bundleDirectory,
  }) {
    return _exclusive(() async {
      final bundle = bundleDirectory.absolute;
      final bundleType = await FileSystemEntity.type(
        bundle.path,
        followLinks: false,
      );
      if (bundleType != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Bundle path is not a directory.',
          bundle.path,
        );
      }
      final manifestFile = File(_join(bundle.path, 'media-index.json'));
      final manifestType = await FileSystemEntity.type(
        manifestFile.path,
        followLinks: false,
      );
      if (manifestType != FileSystemEntityType.file) {
        throw FileSystemException(
          'Bundle index is missing.',
          manifestFile.path,
        );
      }
      final manifestLength = await manifestFile.length();
      if (manifestLength > _maxIndexBytes) {
        throw FormatException('Media index exceeds the size limit.');
      }
      final incoming = _parseIndex(
        await manifestFile.readAsString(encoding: utf8),
      );
      final sourceMediaDirectory = Directory(_join(bundle.path, 'media'));
      final sourceMediaType = await FileSystemEntity.type(
        sourceMediaDirectory.path,
        followLinks: false,
      );
      if (incoming.isNotEmpty &&
          sourceMediaType != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Bundle media folder is missing.',
          sourceMediaDirectory.path,
        );
      }

      // Validate every manifest item and source length before copying anything.
      for (final asset in incoming.values) {
        final source = File(_join(sourceMediaDirectory.path, asset.mediaKey));
        final type = await FileSystemEntity.type(
          source.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) {
          throw FileSystemException(
            'Bundle media file is missing or unsafe.',
            source.path,
          );
        }
        await _verifyManagedFile(source, asset.fileSize);
      }

      final support = await _supportDir();
      final indexFile = File(_join(support.path, 'media-index.json'));
      final current = await _readIndex(indexFile);
      final mediaDirectory = await _mediaDirectory();
      final toCopy = <MediaFileRef>[];
      var skipped = 0;
      for (final asset in incoming.values) {
        final existing = current[asset.mediaKey];
        final target = File(_join(mediaDirectory.path, asset.mediaKey));
        final targetType = await FileSystemEntity.type(
          target.path,
          followLinks: false,
        );
        if (existing != null) {
          if (!_sameIndexedAsset(existing, asset) ||
              targetType != FileSystemEntityType.file) {
            throw FormatException(
              'Imported media key conflicts with an existing asset: ${asset.mediaKey}',
            );
          }
          await _verifyManagedFile(target, existing.fileSize);
          skipped += 1;
        } else {
          if (targetType != FileSystemEntityType.notFound) {
            throw FormatException(
              'Imported media key collides with an unmanaged file: ${asset.mediaKey}',
            );
          }
          toCopy.add(asset);
        }
      }

      final stagingFiles = <String, File>{};
      final movedTargets = <File>[];
      try {
        for (final asset in toCopy) {
          final source = File(_join(sourceMediaDirectory.path, asset.mediaKey));
          final staged = File(
            _join(mediaDirectory.path, '.${asset.mediaKey}.${_newKey()}.part'),
          );
          stagingFiles[asset.mediaKey] = staged;
          final copiedSize = await _copyStreamToFile(
            source.openRead(),
            staged,
            expectedSize: asset.fileSize,
          );
          if (copiedSize != asset.fileSize) {
            throw FormatException('Media size changed during bundle import.');
          }
        }
        for (final asset in toCopy) {
          final staged = stagingFiles[asset.mediaKey]!;
          final target = File(_join(mediaDirectory.path, asset.mediaKey));
          await staged.rename(target.path);
          movedTargets.add(target);
          current[asset.mediaKey] = asset;
        }
        await _writeIndex(indexFile, current);
      } catch (_) {
        for (final staged in stagingFiles.values) {
          if (await staged.exists()) {
            try {
              await staged.delete();
            } on FileSystemException {
              // Preserve the original failure; this is a uniquely named temp.
            }
          }
        }
        for (final target in movedTargets) {
          if (await target.exists()) {
            try {
              await target.delete();
            } on FileSystemException {
              // Preserve the original failure; the key remains unindexed.
            }
          }
        }
        rethrow;
      }

      return MediaBundleImportResult(
        importedCount: toCopy.length,
        skippedCount: skipped,
        assets: List<MediaFileRef>.unmodifiable(incoming.values.toList()),
      );
    });
  }

  Future<MediaFileRef> _storeStream(
    Stream<List<int>> source, {
    required String fileName,
    required String mimeType,
    String? title,
    int? expectedSize,
  }) async {
    if (expectedSize != null && expectedSize > maxFileSizeBytes) {
      throw FormatException('Media file exceeds the configured size limit.');
    }
    final support = await _supportDir();
    final mediaDirectory = await _mediaDirectory();
    final indexFile = File(_join(support.path, 'media-index.json'));
    final assets = await _readIndex(indexFile);

    String mediaKey;
    File destination;
    do {
      mediaKey = _newKey();
      destination = File(_join(mediaDirectory.path, mediaKey));
    } while (assets.containsKey(mediaKey) || await destination.exists());

    final temporary = File('${destination.path}.${_newKey()}.part');
    try {
      final actualSize = await _copyStreamToFile(
        source,
        temporary,
        expectedSize: expectedSize,
      );
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final ref = MediaFileRef(
        mediaKey: mediaKey,
        title: _safeTitle(title, fileName),
        fileName: fileName,
        mimeType: mimeType,
        fileSize: actualSize,
        relativePath: 'media/$mediaKey',
        createdAt: createdAt,
      );
      await temporary.rename(destination.path);
      assets[mediaKey] = ref;
      try {
        await _writeIndex(indexFile, assets);
      } catch (_) {
        if (await destination.exists()) await destination.delete();
        rethrow;
      }
      return ref;
    } catch (_) {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // Do not mask the write or validation error.
        }
      }
      rethrow;
    }
  }

  Future<int> _copyStreamToFile(
    Stream<List<int>> source,
    File destination, {
    int? expectedSize,
  }) async {
    final counter = _ByteCounter();
    final sink = destination.openWrite(mode: FileMode.writeOnly);
    try {
      await sink.addStream(
        _checkedChunks(source, counter, expectedSize: expectedSize),
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (counter.value == 0) {
      throw const FormatException('Media file is empty.');
    }
    if (expectedSize != null && counter.value != expectedSize) {
      throw FormatException(
        'Media file size mismatch: expected $expectedSize bytes, got ${counter.value}.',
      );
    }
    return counter.value;
  }

  Stream<List<int>> _checkedChunks(
    Stream<List<int>> source,
    _ByteCounter counter, {
    int? expectedSize,
  }) async* {
    await for (final chunk in source) {
      counter.value += chunk.length;
      if (counter.value > maxFileSizeBytes) {
        throw FormatException('Media file exceeds the configured size limit.');
      }
      if (expectedSize != null && counter.value > expectedSize) {
        throw FormatException('Media file is larger than its declared size.');
      }
      yield chunk;
    }
  }

  Future<void> _verifyManagedFile(File file, int expectedSize) async {
    if (expectedSize < 0 || expectedSize > maxFileSizeBytes) {
      throw FormatException('Invalid media file size in index.');
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Media path is missing or unsafe.', file.path);
    }
    final actualSize = await file.length();
    if (actualSize != expectedSize) {
      throw FormatException(
        'Media size mismatch for ${_baseName(file.path)}: '
        'expected $expectedSize bytes, got $actualSize.',
      );
    }
  }

  Future<Directory> _supportDir() async =>
      _supportDirectory ?? await getApplicationSupportDirectory();

  Future<Directory> _mediaDirectory() async {
    final support = await _supportDir();
    final media = Directory(_join(support.path, _relativeMediaDirectory));
    final type = await FileSystemEntity.type(media.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw FileSystemException(
        'App media directory cannot be a symbolic link.',
        media.path,
      );
    }
    if (type == FileSystemEntityType.notFound) {
      await media.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'App media path is not a directory.',
        media.path,
      );
    }
    return media;
  }

  Future<Map<String, MediaFileRef>> _readIndex(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return <String, MediaFileRef>{};
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Media index is not a regular file.',
        file.path,
      );
    }
    if (await file.length() > _maxIndexBytes) {
      throw FormatException('Media index exceeds the size limit.');
    }
    return _parseIndex(await file.readAsString(encoding: utf8));
  }

  Map<String, MediaFileRef> _parseIndex(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != _indexFormat ||
        decoded['version'] != _indexVersion ||
        decoded['assets'] is! List<dynamic>) {
      throw const FormatException('Unsupported or malformed media index.');
    }
    final assets = <String, MediaFileRef>{};
    for (final raw in decoded['assets'] as List<dynamic>) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Malformed media index asset.');
      }
      final ref = MediaFileRef.fromJson(
        raw,
        maxFileSizeBytes: maxFileSizeBytes,
      );
      if (assets.containsKey(ref.mediaKey)) {
        throw FormatException('Duplicate media key in index: ${ref.mediaKey}');
      }
      assets[ref.mediaKey] = ref;
    }
    return assets;
  }

  Future<void> _writeIndex(
    File target,
    Map<String, MediaFileRef> assets,
  ) async {
    final json = jsonEncode(_indexJson(assets));
    if (utf8.encode(json).length > _maxIndexBytes) {
      throw FormatException('Media index exceeds the size limit.');
    }
    final temporary = File('${target.path}.${_newKey()}.tmp');
    final backup = File('${target.path}.${_newKey()}.bak');
    await temporary.writeAsString(json, encoding: utf8, flush: true);
    var movedOldIndex = false;
    try {
      if (await target.exists()) {
        await target.rename(backup.path);
        movedOldIndex = true;
      }
      await temporary.rename(target.path);
    } catch (_) {
      if (movedOldIndex && !await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // A uniquely named temp file is safe to leave for later cleanup.
        }
      }
    }
    if (movedOldIndex && await backup.exists()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // The new index is committed; a stale backup is harmless.
      }
    }
  }

  Map<String, Object?> _indexJson(Map<String, MediaFileRef> assets) {
    final sorted = assets.values.toList()..sort(_compareRefs);
    return <String, Object?>{
      'format': _indexFormat,
      'version': _indexVersion,
      'assets': sorted.map((asset) => asset.toJson()).toList(growable: false),
    };
  }

  Future<bool> _isSameOrChild(Directory candidate, Directory root) async {
    String normalized(String path) {
      var value = path.replaceAll('\\', '/');
      while (value.length > 1 && value.endsWith('/')) {
        value = value.substring(0, value.length - 1);
      }
      if (Platform.isWindows) value = value.toLowerCase();
      return value;
    }

    final candidatePath = normalized(candidate.absolute.path);
    final rootPath = normalized(root.absolute.path);
    return candidatePath == rootPath || candidatePath.startsWith('$rootPath/');
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    final previous = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  static int _compareRefs(MediaFileRef left, MediaFileRef right) =>
      left.mediaKey.compareTo(right.mediaKey);

  static bool _sameIndexedAsset(MediaFileRef left, MediaFileRef right) =>
      left.mediaKey == right.mediaKey &&
      left.fileName == right.fileName &&
      left.mimeType == right.mimeType &&
      left.fileSize == right.fileSize &&
      left.relativePath == right.relativePath;

  static String _newKey() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static void _requireMediaKey(String mediaKey) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(mediaKey)) {
      throw FormatException(
        'Media key must be 32 lowercase hexadecimal characters.',
      );
    }
  }

  static String _baseName(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static String _safeBaseName(String value) {
    final name = _baseName(value).trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('\u0000')) {
      throw FormatException('Invalid media file name.');
    }
    return name;
  }

  static String _safeTitle(String? title, String fileName) {
    final normalized = title?.trim();
    return normalized == null || normalized.isEmpty
        ? fileName.replaceFirst(RegExp(r'\.[^.]+$'), '')
        : normalized;
  }

  static String _safeBundleName(String value) {
    final name = value.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-');
    final normalized = name.replaceAll(RegExp(r'\.+$'), '').trim();
    if (normalized.isEmpty || normalized == '.' || normalized == '..') {
      throw ArgumentError.value(
        value,
        'bundleName',
        'Invalid export folder name.',
      );
    }
    return normalized;
  }

  static String _defaultBundleName() {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9TZ]'),
      '',
    );
    return 'lion-media-$stamp';
  }

  static String? _mimeTypeForName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return null;
    final extension = fileName.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'avif' => 'image/avif',
      'tif' || 'tiff' => 'image/tiff',
      'mp3' => 'audio/mpeg',
      'aac' => 'audio/aac',
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'flac' => 'audio/flac',
      'ogg' => 'audio/ogg',
      'opus' => 'audio/opus',
      'amr' => 'audio/amr',
      'mp4' => 'video/mp4',
      'm4v' => 'video/x-m4v',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'mkv' => 'video/x-matroska',
      'avi' => 'video/x-msvideo',
      'wmv' => 'video/x-ms-wmv',
      'flv' => 'video/x-flv',
      '3gp' => 'video/3gpp',
      'pdf' => 'application/pdf',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'doc' => 'application/msword',
      _ => null,
    };
  }

  static bool _isAllowedNewFileName(String fileName) {
    final extension = _extensionForName(fileName);
    return supportedExtensions.contains(extension) ||
        supportedDocumentExtensions.contains(extension);
  }

  static bool _isSupportedDocumentName(String fileName) {
    final extension = _extensionForName(fileName);
    return supportedDocumentExtensions.contains(extension);
  }

  static String _extensionForName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  static String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  static void _ensureNativePlatform(String action) {
    if (kIsWeb) throw UnsupportedError('$action is unavailable on web.');
  }
}

/// File-only metadata returned by [MediaStore]. Pass its fields to the
/// repository metadata API, which records `relativePath` but stores no BLOB.
class MediaFileRef {
  const MediaFileRef({
    required this.mediaKey,
    required this.title,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.relativePath,
    required this.createdAt,
  });

  final String mediaKey;
  final String title;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final String relativePath;
  final String createdAt;

  String get extension => MediaStore._extensionForName(fileName);
  bool get isSupportedDocument =>
      MediaStore.supportedDocumentExtensions.contains(extension);
  bool get isLegacyUnsupportedDoc => extension == 'doc';

  Map<String, Object?> toJson() => <String, Object?>{
    'mediaKey': mediaKey,
    'title': title,
    'fileName': fileName,
    'mimeType': mimeType,
    'fileSize': fileSize,
    'relativePath': relativePath,
    'createdAt': createdAt,
  };

  static MediaFileRef fromJson(
    Map<String, dynamic> json, {
    required int maxFileSizeBytes,
  }) {
    final mediaKey = json['mediaKey'];
    final fileName = json['fileName'];
    final title = json['title'];
    final mimeType = json['mimeType'];
    final fileSize = json['fileSize'];
    final relativePath = json['relativePath'];
    final createdAt = json['createdAt'];
    if (mediaKey is! String ||
        fileName is! String ||
        title is! String ||
        mimeType is! String ||
        fileSize is! int ||
        relativePath is! String ||
        createdAt is! String) {
      throw const FormatException('Malformed media index asset fields.');
    }
    MediaStore._requireMediaKey(mediaKey);
    final safeName = MediaStore._safeBaseName(fileName);
    final inferredMime = MediaStore._mimeTypeForName(safeName);
    if (safeName != fileName ||
        inferredMime == null ||
        inferredMime != mimeType ||
        fileSize <= 0 ||
        fileSize > maxFileSizeBytes ||
        relativePath != 'media/$mediaKey' ||
        DateTime.tryParse(createdAt) == null) {
      throw FormatException('Invalid media index asset: $mediaKey');
    }
    return MediaFileRef(
      mediaKey: mediaKey,
      title: title,
      fileName: fileName,
      mimeType: mimeType,
      fileSize: fileSize,
      relativePath: relativePath,
      createdAt: createdAt,
    );
  }
}

/// Counts copied assets returned by [MediaStore.importBundle].
class MediaBundleImportResult {
  const MediaBundleImportResult({
    required this.importedCount,
    required this.skippedCount,
    required this.assets,
  });

  final int importedCount;
  final int skippedCount;
  final List<MediaFileRef> assets;
}

class _ByteCounter {
  int value = 0;
}
