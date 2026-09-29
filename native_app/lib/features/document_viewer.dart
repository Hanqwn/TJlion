import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:pdfx/pdfx.dart';
import 'package:xml/xml.dart';

/// Opens local PDFs and DOCX files in the app.
///
/// PDFs use pdfx's platform renderer. DOCX files show extracted plain text;
/// document styling, images, and some layout details are not preserved.
class DocumentViewer extends StatefulWidget {
  const DocumentViewer({
    super.key,
    required this.file,
    required this.title,
    this.fileName,
    this.mimeType,
  });

  final File file;
  final String title;
  final String? fileName;
  final String? mimeType;

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  static const int _maxDocxBytes = 16 * 1024 * 1024;

  late final _DocumentFormat _format;
  PdfController? _controller;
  Future<String>? _docxText;
  int? _pageCount;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _format = _documentFormat(
      widget.fileName,
      widget.mimeType,
      widget.file.path,
    );
    if (_format == _DocumentFormat.pdf) {
      _controller = PdfController(
        document: PdfDocument.openFile(widget.file.path),
      );
    } else if (_format == _DocumentFormat.docx) {
      _docxText = _readDocxText();
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.dispose();
      unawaited(
        controller.document
            .then<void>((document) => document.close())
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  Future<String> _readDocxText() async {
    final length = await widget.file.length();
    if (length <= 0) throw const FormatException('DOCX 文件为空。');
    if (length > _maxDocxBytes) {
      throw const FormatException('DOCX 文件超过 16 MB，无法在应用内预览。');
    }
    final bytes = await widget.file.readAsBytes();
    return compute(_extractDocxText, bytes);
  }

  void _onDocumentLoaded(PdfDocument document) {
    if (!mounted) return;
    setState(() {
      _pageCount = document.pagesCount;
      _loadError = null;
    });
  }

  void _onDocumentError(Object error) {
    if (!mounted) return;
    setState(() => _loadError = error);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pdfController = _controller;
    final screenSize = MediaQuery.sizeOf(context);
    final compact = screenSize.width < 720;
    final width = compact ? screenSize.width : 1080.0;
    final height = compact ? screenSize.height : 900.0;
    final maxWidth = screenSize.width < width ? screenSize.width : width;
    final maxHeight = screenSize.height < height ? screenSize.height : height;

    return Dialog(
      insetPadding: compact ? EdgeInsets.zero : const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: maxWidth,
        height: maxHeight,
        child: Column(
          children: [
            Material(
              color: colors.surface,
              child: Padding(
                padding: EdgeInsets.fromLTRB(compact ? 8 : 16, 8, 8, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      tooltip: '关闭文件',
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (_format == _DocumentFormat.pdf &&
                        pdfController != null) ...[
                      const SizedBox(width: 12),
                      ValueListenableBuilder<int>(
                        valueListenable: pdfController.pageListenable,
                        builder: (context, page, _) => Text(
                          '$page / ${_pageCount ?? '…'}',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                      IconButton(
                        onPressed: pdfController.page <= 1
                            ? null
                            : () {
                                pdfController.previousPage(
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOut,
                                );
                              },
                        tooltip: '上一页',
                        icon: const Icon(Icons.chevron_left),
                      ),
                      IconButton(
                        onPressed:
                            _pageCount == null ||
                                pdfController.page >= (_pageCount ?? 0)
                            ? null
                            : () {
                                pdfController.nextPage(
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOut,
                                );
                              },
                        tooltip: '下一页',
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildContent(colors, pdfController)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ColorScheme colors, PdfController? controller) {
    return switch (_format) {
      _DocumentFormat.pdf => _buildPdfContent(colors, controller),
      _DocumentFormat.docx => _buildDocxContent(colors),
      _DocumentFormat.legacyDoc => const _DocumentNotice(
        title: '旧版 DOC 暂不支持',
        message: '应用内纯文本预览支持 DOCX 文件。请使用 DOCX 格式的资料。',
        icon: Icons.article_outlined,
      ),
      _DocumentFormat.unsupported => const _DocumentNotice(
        title: '暂不支持此文件类型',
        message: '当前查看器支持 PDF 和 DOCX 文件。',
        icon: Icons.insert_drive_file_outlined,
      ),
    };
  }

  Widget _buildPdfContent(ColorScheme colors, PdfController? controller) {
    if (_loadError != null) {
      return _DocumentErrorState(title: '无法打开 PDF', error: _loadError!);
    }
    if (controller == null) {
      return const _DocumentNotice(
        title: '无法打开 PDF',
        message: 'PDF 查看器未能初始化。',
        icon: Icons.picture_as_pdf_outlined,
      );
    }
    return PdfView(
      controller: controller,
      scrollDirection: Axis.vertical,
      pageSnapping: false,
      onDocumentLoaded: _onDocumentLoaded,
      onDocumentError: _onDocumentError,
      builders: PdfViewBuilders<DefaultBuilderOptions>(
        options: const DefaultBuilderOptions(),
        documentLoaderBuilder: (_) =>
            const Center(child: CircularProgressIndicator()),
        pageLoaderBuilder: (_) =>
            const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error) =>
            _DocumentErrorState(title: '无法打开 PDF', error: error),
      ),
      backgroundDecoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
      ),
    );
  }

  Widget _buildDocxContent(ColorScheme colors) {
    final future = _docxText;
    if (future == null) {
      return const _DocumentNotice(
        title: '无法读取 DOCX',
        message: 'Word 纯文本解析器未能初始化。',
        icon: Icons.article_outlined,
      );
    }
    return FutureBuilder<String>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _DocumentErrorState(
            title: '无法读取 DOCX',
            error: snapshot.error!,
          );
        }
        final text = snapshot.data?.trim() ?? '';
        if (text.isEmpty) {
          return const _DocumentNotice(
            title: '没有可提取的文字',
            message: '文档可能只包含图片，或没有正文段落。',
            icon: Icons.article_outlined,
          );
        }
        return Column(
          children: [
            Container(
              width: double.infinity,
              color: colors.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text(
                '纯文本预览：文字格式、图片和分页布局可能简化或省略。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSecondaryContainer),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 36),
                child: SelectableText(
                  text,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(height: 1.65),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DocumentErrorState extends StatelessWidget {
  const _DocumentErrorState({required this.title, required this.error});

  final String title;
  final Object error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.picture_as_pdf_outlined, size: 48, color: colors.error),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SelectableText(
              error.toString(),
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

class _DocumentNotice extends StatelessWidget {
  const _DocumentNotice({
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: colors.primary),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
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

enum _DocumentFormat { pdf, docx, legacyDoc, unsupported }

_DocumentFormat _documentFormat(
  String? fileName,
  String? mimeType,
  String path,
) {
  final sourceName = fileName?.trim().isNotEmpty == true
      ? fileName!.trim()
      : path;
  final lowerName = sourceName.toLowerCase();
  final mime = (mimeType ?? '').trim().toLowerCase();
  if (mime == 'application/pdf' || lowerName.endsWith('.pdf')) {
    return _DocumentFormat.pdf;
  }
  if (mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      lowerName.endsWith('.docx')) {
    return _DocumentFormat.docx;
  }
  if (mime == 'application/msword' || lowerName.endsWith('.doc')) {
    return _DocumentFormat.legacyDoc;
  }
  return _DocumentFormat.unsupported;
}

String _extractDocxText(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  if (archive.length > 4096) {
    throw const FormatException('DOCX 包含过多文件，无法在应用内预览。');
  }
  final documentFile = archive.findFile('word/document.xml');
  if (documentFile == null || !documentFile.isFile) {
    throw const FormatException('DOCX 文件缺少正文内容。');
  }
  if (documentFile.size > _maxDocxXmlBytes) {
    throw const FormatException('DOCX 正文内容过大，无法在应用内预览。');
  }
  final xmlBytes = documentFile.readBytes();
  if (xmlBytes == null || xmlBytes.isEmpty) {
    throw const FormatException('DOCX 正文内容为空。');
  }
  final document = XmlDocument.parse(utf8.decode(xmlBytes));
  final paragraphs = document.descendantElements
      .where((element) => element.name.local == 'p')
      .map(_extractParagraphText);
  return paragraphs.join('\n');
}

String _extractParagraphText(XmlElement paragraph) {
  final text = StringBuffer();
  for (final element in paragraph.descendantElements) {
    final name = element.name.local;
    if (name == 't') {
      text.write(element.innerText);
    } else if (name == 'tab') {
      text.write('\t');
    } else if (name == 'br' || name == 'cr') {
      text.write('\n');
    }
  }
  return text.toString();
}

const int _maxDocxXmlBytes = 8 * 1024 * 1024;
