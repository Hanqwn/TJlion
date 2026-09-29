import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../data/models.dart';
import '../services/media_store.dart';

Future<void> showMediaViewer({
  required BuildContext context,
  required MediaStore mediaStore,
  required MediaAssetModel asset,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => MediaViewer(mediaStore: mediaStore, asset: asset),
  );
}

class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.mediaStore, required this.asset});

  final MediaStore mediaStore;
  final MediaAssetModel asset;

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  File? _file;
  VideoPlayerController? _controller;
  String? _error;
  bool _loading = true;

  _MediaKind get _kind => _mediaKind(widget.asset);

  @override
  void initState() {
    super.initState();
    _resolveAndOpen();
  }

  Future<void> _resolveAndOpen() async {
    try {
      final file = await widget.mediaStore.resolveFile(widget.asset.mediaKey);
      if (file == null) throw StateError('本机找不到这个附件文件。');
      if (!mounted) return;

      _file = file;
      if (_kind == _MediaKind.image) {
        setState(() => _loading = false);
        return;
      }

      if (_kind == _MediaKind.unsupported) {
        setState(() => _loading = false);
        return;
      }

      final controller = VideoPlayerController.file(file);
      _controller = controller;
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _loading = false);
    } catch (error) {
      final controller = _controller;
      _controller = null;
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
      if (controller != null) await controller.dispose();
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final maxHeight = math
        .max(240.0, math.min(820.0, size.height - 32))
        .toDouble();
    final title = widget.asset.title.trim().isEmpty
        ? widget.asset.fileName
        : widget.asset.title.trim();

    return Dialog(
      insetPadding: EdgeInsets.all(size.width < 560 ? 12 : 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 1080, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ViewerHeader(
              title: title,
              fileName: widget.asset.fileName,
              fileSize: widget.asset.fileSize,
              kind: _kind,
            ),
            const Divider(height: 1),
            Flexible(child: _buildContent(title)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(String title) {
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final error = _error;
    if (error != null) return _ViewerError(message: error);

    final file = _file;
    if (file == null) {
      return const _ViewerError(message: '本机找不到这个附件文件。');
    }

    return switch (_kind) {
      _MediaKind.image => Padding(
        padding: const EdgeInsets.all(12),
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) =>
                _ViewerError(message: '无法显示这张图片：' + error.toString()),
          ),
        ),
      ),
      _MediaKind.audio || _MediaKind.video =>
        _controller == null
            ? const _ViewerError(message: '播放器未能启动。')
            : _PlaybackView(
                controller: _controller!,
                kind: _kind,
                title: title,
              ),
      _MediaKind.unsupported => _ViewerError(
        message: '暂不支持预览此文件类型（' + widget.asset.mimeType + '）。',
      ),
    };
  }
}

class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader({
    required this.title,
    required this.fileName,
    required this.fileSize,
    required this.kind,
  });

  final String title;
  final String fileName;
  final int fileSize;
  final _MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final icon = switch (kind) {
      _MediaKind.image => Icons.image_outlined,
      _MediaKind.video => Icons.movie_outlined,
      _MediaKind.audio => Icons.music_note_rounded,
      _MediaKind.unsupported => Icons.insert_drive_file_outlined,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: colors.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  fileName + ' · ' + _formatFileSize(fileSize),
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
            tooltip: '关闭预览',
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _PlaybackView extends StatelessWidget {
  const _PlaybackView({
    required this.controller,
    required this.kind,
    required this.title,
  });

  final VideoPlayerController controller;
  final _MediaKind kind;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, child) {
        if (value.hasError) {
          return _ViewerError(message: value.errorDescription ?? '媒体无法播放。');
        }
        if (!value.isInitialized) {
          return const SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final durationMs = value.duration.inMilliseconds;
        final positionMs = value.position.inMilliseconds
            .clamp(0, math.max(0, durationMs))
            .toDouble();

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: kind == _MediaKind.video
                  ? _VideoSurface(controller: controller, value: value)
                  : _AudioSurface(title: title),
            ),
            _PlaybackControls(
              controller: controller,
              value: value,
              positionMs: positionMs,
              durationMs: durationMs,
            ),
          ],
        );
      },
    );
  }
}

class _VideoSurface extends StatelessWidget {
  const _VideoSurface({required this.controller, required this.value});

  final VideoPlayerController controller;
  final VideoPlayerValue value;

  @override
  Widget build(BuildContext context) {
    final ratio = value.aspectRatio.isFinite && value.aspectRatio > 0
        ? value.aspectRatio
        : 16 / 9;

    return Container(
      width: double.infinity,
      color: Colors.black,
      alignment: Alignment.center,
      child: AspectRatio(aspectRatio: ratio, child: VideoPlayer(controller)),
    );
  }
}

class _AudioSurface extends StatelessWidget {
  const _AudioSurface({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.graphic_eq_rounded,
                size: 54,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.controller,
    required this.value,
    required this.positionMs,
    required this.durationMs,
  });

  final VideoPlayerController controller;
  final VideoPlayerValue value;
  final double positionMs;
  final int durationMs;

  void _togglePlayback() {
    if (value.isPlaying) {
      unawaited(controller.pause());
    } else if (value.isCompleted) {
      unawaited(
        controller.seekTo(Duration.zero).then((_) => controller.play()),
      );
    } else {
      unawaited(controller.play());
    }
  }

  void _seekBy(int seconds) {
    final target = value.position + Duration(seconds: seconds);
    final bounded = target < Duration.zero
        ? Duration.zero
        : target > value.duration
        ? value.duration
        : target;
    unawaited(controller.seekTo(bounded));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final maxValue = math.max(1, durationMs).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '后退 10 秒',
                onPressed: () => _seekBy(-10),
                icon: const Icon(Icons.replay_10_rounded),
              ),
              IconButton.filledTonal(
                tooltip: value.isPlaying ? '暂停' : '播放',
                onPressed: _togglePlayback,
                icon: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                tooltip: '前进 10 秒',
                onPressed: () => _seekBy(10),
                icon: const Icon(Icons.forward_10_rounded),
              ),
              const Spacer(),
              Text(
                _formatDuration(value.position) +
                    ' / ' +
                    _formatDuration(value.duration),
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          Slider(
            value: positionMs.clamp(0, maxValue).toDouble(),
            max: maxValue,
            onChanged: durationMs <= 0
                ? null
                : (value) {
                    unawaited(
                      controller.seekTo(Duration(milliseconds: value.round())),
                    );
                  },
          ),
        ],
      ),
    );
  }
}

class _ViewerError extends StatelessWidget {
  const _ViewerError({required this.message});

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
            Icon(Icons.warning_amber_rounded, size: 46, color: colors.error),
            const SizedBox(height: 12),
            Text(
              '无法打开媒体',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SelectableText(
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

enum _MediaKind { image, video, audio, unsupported }

_MediaKind _mediaKind(MediaAssetModel asset) {
  final mimeType = asset.mimeType.toLowerCase();
  if (mimeType.startsWith('image/')) return _MediaKind.image;
  if (mimeType.startsWith('video/')) return _MediaKind.video;
  if (mimeType.startsWith('audio/')) return _MediaKind.audio;

  final dot = asset.fileName.lastIndexOf('.');
  final extension = dot < 0
      ? ''
      : asset.fileName.substring(dot + 1).toLowerCase();
  const imageExtensions = {
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
  };
  const videoExtensions = {
    'mp4',
    'm4v',
    'mov',
    'webm',
    'mkv',
    'avi',
    'wmv',
    'flv',
    '3gp',
  };
  const audioExtensions = {
    'mp3',
    'aac',
    'm4a',
    'wav',
    'flac',
    'ogg',
    'opus',
    'amr',
  };

  if (imageExtensions.contains(extension)) return _MediaKind.image;
  if (videoExtensions.contains(extension)) return _MediaKind.video;
  if (audioExtensions.contains(extension)) return _MediaKind.audio;
  return _MediaKind.unsupported;
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return bytes.toString() + ' B';
  if (bytes < 1024 * 1024) {
    return (bytes / 1024).toStringAsFixed(1) + ' KiB';
  }
  return (bytes / (1024 * 1024)).toStringAsFixed(1) + ' MiB';
}

String _formatDuration(Duration duration) {
  final totalSeconds = math.max(0, duration.inSeconds).toInt();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final secondText = seconds.toString().padLeft(2, '0');
  final minuteText = hours > 0
      ? minutes.toString().padLeft(2, '0')
      : '$minutes';
  return hours > 0 ? '$hours:$minuteText:$secondText' : '$minutes:$secondText';
}
